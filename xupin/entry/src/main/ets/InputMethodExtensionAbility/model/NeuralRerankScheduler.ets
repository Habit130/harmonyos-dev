// Issue #24 E1/E2: how long to wait after the last keystroke before firing a neural rerank —
// the debounce window that replaces #22's "rerank on every keystroke" (D6/D8, both explicitly
// revoked by issue #24). Named/tunable per the issue's own instruction ("防抖窗口是具名常量"),
// starting point 200ms per the issue's grilling.
export const DEFAULT_NEURAL_DEBOUNCE_MS: number = 200;

/**
 * Thin seam over `setTimeout`/`clearTimeout` so `NeuralRerankScheduler` below is unit-testable
 * without a real timer — tests inject a fake that captures scheduled callbacks instead of
 * waiting out real milliseconds (see NeuralRerankScheduler.test.ets). `TimerScheduler` is the
 * only production implementation, used by Index.ets.
 */
export interface Scheduler {
  schedule(callback: () => void, delayMs: number): number;
  cancel(handle: number): void;
}

export class TimerScheduler implements Scheduler {
  schedule(callback: () => void, delayMs: number): number {
    return setTimeout(callback, delayMs);
  }

  cancel(handle: number): void {
    clearTimeout(handle);
  }
}

/**
 * Debounces neural rerank requests: `request()` cancels whatever it previously scheduled and
 * reschedules `delayMs` out, so a burst of keystrokes only ever leaves ONE pending callback —
 * the one from the last `request()` call — and only that one ever fires. This is issue #24's
 * "连续打字期间不发起任何 predict()" requirement; Index.ets calls `request()` on every keystroke
 * and only its final callback (the neural rerank) actually runs, `delayMs` after typing stops.
 *
 * Owns only the timing decision, not what happens on fire — Index.ets supplies that as the
 * callback, same separation `rankCandidates()` already draws between "when" and "what".
 */
export class NeuralRerankScheduler {
  private readonly scheduler: Scheduler;
  private readonly delayMs: number;
  private pendingHandle: number | undefined = undefined;

  constructor(scheduler: Scheduler, delayMs?: number) {
    this.scheduler = scheduler;
    this.delayMs = delayMs ?? DEFAULT_NEURAL_DEBOUNCE_MS;
  }

  request(callback: () => void): void {
    this.cancel();
    this.pendingHandle = this.scheduler.schedule(callback, this.delayMs);
  }

  /** Drops any pending callback without firing it — issue #24 phase 1 item 5: confirm()ing a
   * candidate clears the buffer, so whatever rerank was pending for the pre-confirm buffer must
   * not run. Index.ets's refreshCandidates() calls this (via its empty-buffer branch) or
   * effectively re-triggers it (via request()'s own cancel-then-reschedule) on every call, so
   * callers don't need to invoke this directly except where no request() follows in the same
   * turn (composition reset). */
  cancel(): void {
    if (this.pendingHandle !== undefined) {
      this.scheduler.cancel(this.pendingHandle);
      this.pendingHandle = undefined;
    }
  }
}
