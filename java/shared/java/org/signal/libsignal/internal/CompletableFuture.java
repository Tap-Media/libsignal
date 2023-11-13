//
// Copyright 2023 Signal Messenger, LLC.
// SPDX-License-Identifier: AGPL-3.0-only
//

package org.signal.libsignal.internal;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CancellationException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.Consumer;
import java.util.function.Function;

/** A stripped-down, Android-21-compatible version of java.util.concurrent.CompletableFuture. */
public class CompletableFuture<T> implements Future<T> {
  private boolean completed;
  private T result;
  private Throwable exception;
  private List<ThenApplyCompleter> consumers;

  public CompletableFuture() {
    this.consumers = new ArrayList<>();
  }

  @Override
  public synchronized boolean cancel(boolean mayInterruptIfRunning) {
    // We do not currently support cancellation.
    return false;
  }

  @Override
  public synchronized boolean isCancelled() {
    return false;
  }

  @Override
  public synchronized boolean isDone() {
    return completed;
  }

  public synchronized boolean complete(T result) {
    if (completed) return false;

    this.result = result;
    this.completed = true;

    notifyAll();

    for (ThenApplyCompleter completer : this.consumers) {
      completer.complete.accept(result);
    }

    return true;
  }

  public synchronized boolean completeExceptionally(Throwable throwable) {
    if (completed) return false;

    if (throwable == null) {
      throwable = new AssertionError("Future failed, but no exception provided");
    }

    this.exception = throwable;
    this.completed = true;

    notifyAll();

    for (ThenApplyCompleter completer : this.consumers) {
      completer.completeExceptionally.accept(throwable);
    }

    return true;
  }

  @Override
  public synchronized T get()
      throws CancellationException, ExecutionException, InterruptedException {
    while (!completed) wait();

    if (exception != null) throw new ExecutionException(exception);

    return result;
  }

  @Override
  public synchronized T get(long timeout, TimeUnit unit)
      throws CancellationException, ExecutionException, InterruptedException, TimeoutException {
    long deadlineMillis = System.currentTimeMillis() + unit.toMillis(timeout);

    while (!completed) {
      long remainingMillis = deadlineMillis - System.currentTimeMillis();
      if (remainingMillis <= 0) {
        throw new TimeoutException();
      }

      wait(remainingMillis);
    }

    return get();
  }

  public <U> CompletableFuture<U> thenApply(Function<? super T, ? extends U> fn) {
    CompletableFuture<U> future = new CompletableFuture<>();
    ThenApplyCompleter completer = new ThenApplyCompleter(future, fn);

    synchronized (this) {
      this.consumers.add(completer);
    }

    return future;
  }

  private class ThenApplyCompleter {
    private <U> ThenApplyCompleter(
        CompletableFuture<U> future, Function<? super T, ? extends U> fn) {
      this.complete =
          (T value) -> {
            future.complete(fn.apply(value));
          };
      this.completeExceptionally =
          (Throwable throwable) -> {
            future.completeExceptionally(throwable);
          };
    }

    private Consumer<T> complete;
    private Consumer<Throwable> completeExceptionally;
  }
}
