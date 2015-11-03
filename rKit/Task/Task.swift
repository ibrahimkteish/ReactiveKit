//
//  Task.swift
//  rTasks
//
//  Created by Srdan Rasic on 30/10/15.
//  Copyright © 2015 Srdan Rasic. All rights reserved.
//

public protocol TaskType: StreamType {
  typealias Value
  typealias Error: ErrorType

  func lift<U, F: ErrorType>(transform: Stream<TaskEvent<Value, Error>> -> Stream<TaskEvent<U, F>>) -> Task<U, F>
  func observe(on context: ExecutionContext, sink: TaskEvent<Value, Error> -> ()) -> DisposableType
}

public struct Task<Value, Error: ErrorType>: TaskType {
  
  private let stream: Stream<TaskEvent<Value, Error>>
  
  public init(stream: Stream<TaskEvent<Value, Error>>) {
    self.stream = stream
  }
  
  public init(producer: (TaskSink<Value, Error> -> DisposableType?)) {
    stream = Stream  { sink in
      var completed: Bool = false
      
      return producer(TaskSink { event in
        if !completed {
          sink(event)
        }
        
        completed = event._unbox.isTerminal
      })
    }
  }
  
  public func observe(on context: ExecutionContext, sink: TaskEvent<Value, Error> -> ()) -> DisposableType {
    return stream.observe(on: context, sink: sink)
  }
  
  public static func succeeded(with value: Value) -> Task<Value, Error> {
    return create { sink in
      sink.next(value)
      sink.success()
      return nil
    }
  }
  
  public static func failed(with error: Error) -> Task<Value, Error> {
    return create { sink in
      sink.failure(error)
      return nil
    }
  }
  
  public func lift<U, F: ErrorType>(transform: Stream<TaskEvent<Value, Error>> -> Stream<TaskEvent<U, F>>) -> Task<U, F> {
    return Task<U, F>(stream: transform(self.stream))
  }
}


public func create<Value, Error: ErrorType>(producer producer: TaskSink<Value, Error> -> DisposableType?) -> Task<Value, Error> {
  return Task<Value, Error> { sink in
    return producer(sink)
  }
}

public extension TaskType {
  
  public func observeNext(on context: ExecutionContext, sink: Value -> ()) -> DisposableType {
    return self.observe(on: context) { event in
      switch event {
      case .Next(let event):
        sink(event)
      default: break
      }
    }
  }
  
  public func observeError(on context: ExecutionContext, sink: Error -> ()) -> DisposableType {
    return self.observe(on: context) { event in
      switch event {
      case .Failure(let error):
        sink(error)
      default: break
      }
    }
  }
  
  @warn_unused_result
  public func map<U>(transform: Value -> U) -> Task<U, Error> {
    return lift { $0.map { $0.map(transform) } }
  }
  
  @warn_unused_result
  public func mapError<F>(transform: Error -> F) -> Task<Value, F> {
    return lift { $0.map { $0.mapError(transform) } }
  }
  
  @warn_unused_result
  public func filter(include: Value -> Bool) -> Task<Value, Error> {
    return lift { $0.filter { $0.filter(include) } }
  }
  
  @warn_unused_result
  public func switchTo(context: ExecutionContext) -> Task<Value, Error> {
    return lift { $0.switchTo(context) }
  }
  
  @warn_unused_result
  public func throttle(seconds: Double, on queue: Queue) -> Task<Value, Error> {
    return lift { $0.throttle(seconds, on: queue) }
  }
  
  @warn_unused_result
  public func skip(count: Int) -> Task<Value, Error> {
    return lift { $0.skip(count) }
  }

  @warn_unused_result
  public func startWith(event: Value) -> Task<Value, Error> {
    return lift { $0.startWith(.Next(event)) }
  }
  
  @warn_unused_result
  public func combineLatestWith<S: TaskType where S.Error == Error>(other: S) -> Task<(Value, S.Value), Error> {
    return create { sink in
      var latestSelfValue: Value! = nil
      var latestOtherValue: S.Value! = nil
      
      var latestSelfEvent: TaskEvent<Value, Error>! = nil
      var latestOtherEvent: TaskEvent<S.Value, S.Error>! = nil
      
      let dispatchNextIfPossible = { () -> () in
        if let latestSelfValue = latestSelfValue, latestOtherValue = latestOtherValue {
          sink.next(latestSelfValue, latestOtherValue)
        }
      }
      
      let onBoth = { () -> () in
        if let latestSelfEvent = latestSelfEvent, let latestOtherEvent = latestOtherEvent {
          switch (latestSelfEvent, latestOtherEvent) {
          case (.Success, .Success):
            sink.success()
          case (.Next(let selfValue), .Next(let otherValue)):
            latestSelfValue = selfValue
            latestOtherValue = otherValue
            dispatchNextIfPossible()
          case (.Next(let selfValue), .Success):
            latestSelfValue = selfValue
            dispatchNextIfPossible()
          case (.Success, .Next(let otherValue)):
            latestOtherValue = otherValue
            dispatchNextIfPossible()
          default:
            dispatchNextIfPossible()
          }
        }
      }
      
      let selfDisposable = self.observe(on: ImmediateExecutionContext) { event in
        if case .Failure(let error) = event {
          sink.failure(error)
        } else {
          latestSelfEvent = event
          onBoth()
        }
      }
      
      let otherDisposable = other.observe(on: ImmediateExecutionContext) { event in
        if case .Failure(let error) = event {
          sink.failure(error)
        } else {
          latestOtherEvent = event
          onBoth()
        }
      }
      
      return CompositeDisposable([selfDisposable, otherDisposable])
    }
  }

}

public extension TaskType where Value: OptionalType {
  
  @warn_unused_result
  public func ignoreNil() -> Task<Value.Wrapped?, Error> {
    return lift { $0.filter { $0.filter { $0._unbox != nil } }.map { $0.map { $0._unbox! } } }
  }
}

public extension TaskType where Value: TaskType, Value.Error == Error {
  
  @warn_unused_result
  public func merge() -> Task<Value.Value, Value.Error> {
    return create { sink in
      
      var numberOfTasks = 0
      var outerCompleted = false
      let compositeDisposable = CompositeDisposable()
      
      let decrementNumberOfTasks = { () -> () in
        numberOfTasks -= 1
        if numberOfTasks == 0 && outerCompleted {
          sink.success()
        }
      }
      
      compositeDisposable += self.observe(on: ImmediateExecutionContext) { taskEvent in
        
        switch taskEvent {
        case .Failure(let error):
          return sink.failure(error)
        case .Success:
          outerCompleted = true
          if numberOfTasks > 0 {
            decrementNumberOfTasks()
          } else {
            sink.success()
          }
        case .Next(let task):
          numberOfTasks += 1
          compositeDisposable += task.observe(on: ImmediateExecutionContext) { event in
            switch event {
            case .Next, .Failure:
              sink.sink(event)
            case .Success:
              decrementNumberOfTasks()
            }
          }
        }
      }
      return compositeDisposable
    }
  }
  
  @warn_unused_result
  public func switchToLatest() -> Task<Value.Value, Value.Error>  {
    return create { sink in
      let serialDisposable = SerialDisposable(otherDisposable: nil)
      let compositeDisposable = CompositeDisposable([serialDisposable])
      
      var outerCompleted: Bool = false
      var innerCompleted: Bool = false
      
      compositeDisposable += self.observe(on: ImmediateExecutionContext) { taskEvent in
        
        switch taskEvent {
        case .Failure(let error):
          sink.failure(error)
        case .Success:
          outerCompleted = true
          if innerCompleted {
            sink.success()
          }
        case .Next(let innerTask):
          serialDisposable.otherDisposable?.dispose()
          serialDisposable.otherDisposable = innerTask.observe(on: ImmediateExecutionContext) { event in
            
            switch event {
            case .Failure(let error):
              sink.failure(error)
            case .Success:
              innerCompleted = true
              if outerCompleted {
                sink.success()
              }
            case .Next(let value):
              sink.next(value)
            }
          }
        }
      }
      
      return compositeDisposable
    }
  }
  
  @warn_unused_result
  public func concat() -> Task<Value.Value, Value.Error>  {
    return create { sink in
      let serialDisposable = SerialDisposable(otherDisposable: nil)
      let compositeDisposable = CompositeDisposable([serialDisposable])
      
      var outerCompleted: Bool = false
      var innerCompleted: Bool = true
      
      var taskQueue: [Value] = []
      
      var startNextTask: (() -> ())! = nil
      startNextTask = {
        innerCompleted = false
        let task = taskQueue.removeAtIndex(0)
        
        serialDisposable.otherDisposable?.dispose()
        serialDisposable.otherDisposable = task.observe(on: ImmediateExecutionContext) { event in
          switch event {
          case .Failure(let error):
            sink.failure(error)
          case .Success:
            innerCompleted = true
            if taskQueue.count > 0 {
              startNextTask()
            } else if outerCompleted {
              sink.success()
            }
          case .Next(let value):
            sink.next(value)
          }
        }
      }
      
      let addToQueue = { (task: Value) -> () in
        taskQueue.append(task)
        if innerCompleted {
          startNextTask()
        }
      }

      compositeDisposable += self.observe(on: ImmediateExecutionContext) { taskEvent in
        
        switch taskEvent {
        case .Failure(let error):
          sink.failure(error)
        case .Success:
          outerCompleted = true
          if innerCompleted {
            sink.success()
          }
        case .Next(let innerTask):
          addToQueue(innerTask)
        }
      }
      
      return compositeDisposable
    }
  }
}

public enum TaskFlatMapStrategy {
  case Latest
  case Merge
  case Concat
}

public extension TaskType {
  
  @warn_unused_result
  public func flatMap<T: TaskType where T.Error == Error>(strategy: TaskFlatMapStrategy, transform: Value -> T) -> Task<T.Value, T.Error> {
    switch strategy {
    case .Latest:
      return map(transform).switchToLatest()
    case .Merge:
      return map(transform).merge()
    case .Concat:
      return map(transform).concat()
    }
  }
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType where A.Error == B.Error>(a: A, _ b: B) -> Task<(A.Value, B.Value), A.Error> {
  return a.combineLatestWith(b)
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType, C: TaskType where A.Error == B.Error, A.Error == C.Error>(a: A, _ b: B, _ c: C) -> Task<(A.Value, B.Value, C.Value), A.Error> {
  return combineLatest(a, b).combineLatestWith(c).map { ($0.0, $0.1, $1) }
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType, C: TaskType, D: TaskType where A.Error == B.Error, A.Error == C.Error, A.Error == D.Error>(a: A, _ b: B, _ c: C, _ d: D) -> Task<(A.Value, B.Value, C.Value, D.Value), A.Error> {
  return combineLatest(a, b, c).combineLatestWith(d).map { ($0.0, $0.1, $0.2, $1) }
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType, C: TaskType, D: TaskType, E: TaskType where A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error>
  (a: A, _ b: B, _ c: C, _ d: D, _ e: E) -> Task<(A.Value, B.Value, C.Value, D.Value, E.Value), A.Error>
{
  return combineLatest(a, b, c, d).combineLatestWith(e).map { ($0.0, $0.1, $0.2, $0.3, $1) }
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType, C: TaskType, D: TaskType, E: TaskType, F: TaskType where A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F) -> Task<(A.Value, B.Value, C.Value, D.Value, E.Value, F.Value), A.Error>
{
  return combineLatest(a, b, c, d, e).combineLatestWith(f).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $1) }
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType, C: TaskType, D: TaskType, E: TaskType, F: TaskType, G: TaskType where A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G) -> Task<(A.Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value), A.Error>
{
  return combineLatest(a, b, c, d, e, f).combineLatestWith(g).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $1) }
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType, C: TaskType, D: TaskType, E: TaskType, F: TaskType, G: TaskType, H: TaskType where A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H) -> Task<(A.Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value), A.Error>
{
  return combineLatest(a, b, c, d, e, f, g).combineLatestWith(h).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $1) }
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType, C: TaskType, D: TaskType, E: TaskType, F: TaskType, G: TaskType, H: TaskType, I: TaskType where A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error, A.Error == I.Error>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I) -> Task<(A.Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value, I.Value), A.Error>
{
  return combineLatest(a, b, c, d, e, f, g, h).combineLatestWith(i).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7, $1) }
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType, C: TaskType, D: TaskType, E: TaskType, F: TaskType, G: TaskType, H: TaskType, I: TaskType, J: TaskType where A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error, A.Error == I.Error, A.Error == J.Error>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I, _ j: J) -> Task<(A.Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value, I.Value, J.Value), A.Error>
{
  return combineLatest(a, b, c, d, e, f, g, h, i).combineLatestWith(j).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7, $0.8, $1) }
}

@warn_unused_result
public func combineLatest<A: TaskType, B: TaskType, C: TaskType, D: TaskType, E: TaskType, F: TaskType, G: TaskType, H: TaskType, I: TaskType, J: TaskType, K: TaskType where A.Error == B.Error, A.Error == C.Error, A.Error == D.Error, A.Error == E.Error, A.Error == F.Error, A.Error == G.Error, A.Error == H.Error, A.Error == I.Error, A.Error == J.Error, A.Error == K.Error>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I, _ j: J, _ k: K) -> Task<(A.Value, B.Value, C.Value, D.Value, E.Value, F.Value, G.Value, H.Value, I.Value, J.Value, K.Value), A.Error>
{
  return combineLatest(a, b, c, d, e, f, g, h, i, j).combineLatestWith(k).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7, $0.8, $0.9, $1) }
}
