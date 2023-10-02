//
//  File.swift
//
//
//  Created by shotaro.hirano on 2023/10/02.
//

import Combine

/**
 This function takes an array as an argument and continues to emit events to the elements' Publisher until it succeeds. If it fails or the array is empty, it returns an error.
 And, the array of Publishers should be used with Deferred operator, as shown in the example.
# Code Example
 ```
 extension Sequence where Element == VideoRewardAdFetcher {
     func fetch() -> AnyPublisher<PlayableVideoRewardAd, Error> {
         var observableSequence: [AnyPublisher<PlayableVideoRewardAd, Error>] = map { fetcher in
             Deferred {
                 fetcher.fetch()
                     .timeout(5 , scheduler: DispatchQueue.main)
                     .map { PlayableVideoRewardAd(fetcher: fetcher) }
                     .prefix(1)
                     .eraseToAnyPublisher()
             }.eraseToAnyPublisher()
         }
         
         return Publishers.catchArray(observableSequence).eraseToAnyPublisher()
     }
 }
 ```
*/
public extension Publishers {
    static func catchArray<P: Publisher, Result>(_ publishers: [P],
                                                 resultSelector: @escaping (P.Output) -> Result) -> Publishers.CatchArray<P, Result> {
        return .init(publishers: publishers, resultSelector: resultSelector)
    }
    
    static func catchArray<P: Publisher, Result>(_ publishers: [P]) -> Publishers.CatchArray<P, Result> where P.Output == Result {
        let resultSelector = { (output: P.Output) -> Result in
            return output
        }
        return .init(publishers: publishers, resultSelector: resultSelector)
    }
}

public extension Publisher {
    func catchArray<P: Publisher, Result>(_ publishers: [P],
                                          resultSelector: @escaping (P.Output) -> Result) -> Publishers.CatchArray<P, Result> {
        return .init(publishers: publishers, resultSelector: resultSelector)
    }
    
    func catchArray<P: Publisher, Result>(_ publishers: [P]) -> Publishers.CatchArray<P, Result> where P.Output == Result {
        let resultSelector = { (output: P.Output) -> Result in
            return output
        }
        return .init(publishers: publishers, resultSelector: resultSelector)
    }
}

extension Publishers {
    public struct CatchArray<P: Publisher,
                             Output>: Publisher where P.Failure == Error {
        public typealias Failure = Error
        public typealias ResultSelector = (P.Output) -> Output
        
        private let publishers: [P]
        private let resultSelector: ResultSelector
        
        public enum ErrorType: Error {
            case noElement
            case shouldNextRequestError
            case noSelf
        }
        
        init(publishers: [P],
             resultSelector: @escaping ResultSelector) {
            self.publishers = publishers
            self.resultSelector = resultSelector
        }
        
        public func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, Output == S.Input {
            let sub = Subscription(subscriber: subscriber, resultSelector: resultSelector, publishers: publishers)
            subscriber.receive(subscription: sub)
        }
    }
}

extension Publishers.CatchArray {
    private class Subscription<S: Subscriber>: Combine.Subscription where S.Input == Output, S.Failure == Failure {
        private let subscriber: S
        private let resultSelector: ResultSelector
        private var publishers: [P]
        private var cancellable: Cancellable?
        
        init(subscriber: S, resultSelector: @escaping ResultSelector, publishers: [P]) {
            self.subscriber = subscriber
            self.resultSelector = resultSelector
            self.publishers = publishers
        }
        
        func request(_ demand: Subscribers.Demand) {
            startArrayRequest()
        }
        
        private func startArrayRequest() {
            guard let firstPub = self.publishers.first else {
                subscriber.receive(completion: .failure(ErrorType.noElement))
                return
            }
            cancellable = Publishers.Catch(upstream: firstPub) { _ in
                return Fail<P.Output, P.Failure>(error: ErrorType.shouldNextRequestError).eraseToAnyPublisher()
            }.sink(receiveCompletion: { [weak self, subscriber] completion in
                guard let self else {
                    subscriber.receive(completion: .failure(ErrorType.noSelf))
                    return
                }
                switch completion {
                case .finished:
                    subscriber.receive(completion: completion)
                case .failure(let error):
                    switch error {
                    case ErrorType.shouldNextRequestError:
                        self.publishers = self.publishers.dropFirst().map { $0 }
                        self.startArrayRequest()
                    default:
                        subscriber.receive(completion: completion)
                    }
                }
            }, receiveValue: { [weak self] output in
                guard let self else {
                    self?.subscriber.receive(completion: .failure(ErrorType.noSelf))
                    return
                }
                _ = subscriber.receive(self.resultSelector(output))
            })
        }
        
        func cancel() {
            cancellable?.cancel()
        }
    }
}
