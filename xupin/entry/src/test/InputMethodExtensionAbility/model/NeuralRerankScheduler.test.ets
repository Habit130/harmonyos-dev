import { describe, it, expect } from '@ohos/hypium';
import {
  DEFAULT_NEURAL_DEBOUNCE_MS,
  NeuralRerankScheduler,
  Scheduler
} from '../../../main/ets/InputMethodExtensionAbility/model/NeuralRerankScheduler';

/**
 * Records every schedule()/cancel() call and lets a test fire a still-pending callback on
 * demand, without waiting out real milliseconds — the seam NeuralRerankScheduler.ets's doc
 * describes. A class, not a plain object, for the same arkts-no-untyped-obj-literals reason
 * NeuralScorer.test.ets's ArrayRowLogits is a class (see that file).
 */
class FakeScheduler implements Scheduler {
  private nextHandle: number = 1;
  private readonly pending: Map<number, () => void> = new Map();
  scheduleCalls: number[] = []; // delayMs passed to each schedule() call, in order
  cancelledHandles: number[] = [];

  schedule(callback: () => void, delayMs: number): number {
    const handle = this.nextHandle;
    this.nextHandle++;
    this.pending.set(handle, callback);
    this.scheduleCalls.push(delayMs);
    return handle;
  }

  cancel(handle: number): void {
    this.cancelledHandles.push(handle);
    this.pending.delete(handle);
  }

  isPending(handle: number): boolean {
    return this.pending.has(handle);
  }

  fire(handle: number): void {
    const callback = this.pending.get(handle);
    if (callback === undefined) {
      throw new Error('FakeScheduler: no pending callback for handle ' + handle);
    }
    callback();
  }
}

export default function neuralRerankSchedulerTest() {
  describe('NeuralRerankSchedulerTest', () => {
    it('request() schedules with DEFAULT_NEURAL_DEBOUNCE_MS when no delay is given', 0, () => {
      const fake = new FakeScheduler();
      const scheduler = new NeuralRerankScheduler(fake);
      scheduler.request(() => {});
      expect(fake.scheduleCalls).assertDeepEquals([DEFAULT_NEURAL_DEBOUNCE_MS]);
    });

    it('a burst of request() calls (simulated rapid typing) cancels every prior pending callback — only the LAST one ever fires, proving predict() would run at most once per burst', 0, () => {
      const fake = new FakeScheduler();
      const scheduler = new NeuralRerankScheduler(fake, 200);
      let call1 = 0;
      let call2 = 0;
      let call3 = 0;
      scheduler.request(() => { call1++; });
      scheduler.request(() => { call2++; });
      scheduler.request(() => { call3++; });

      expect(fake.scheduleCalls.length).assertEqual(3); // one schedule() per keystroke
      expect(fake.cancelledHandles).assertDeepEquals([1, 2]); // the first two were cancelled...
      expect(fake.isPending(3)).assertTrue(); // ...only the third is still pending

      fake.fire(3); // simulates "typing stopped for 200ms"
      expect(call1).assertEqual(0);
      expect(call2).assertEqual(0);
      expect(call3).assertEqual(1); // only the last keystroke's rerank actually ran
    });

    it('cancel() drops a pending callback without firing it (issue #24 phase 1 item 5: confirm() must not trigger a stale rerank)', 0, () => {
      const fake = new FakeScheduler();
      const scheduler = new NeuralRerankScheduler(fake, 200);
      let fired = false;
      scheduler.request(() => { fired = true; });
      scheduler.cancel();

      expect(fake.cancelledHandles).assertDeepEquals([1]);
      expect(fake.isPending(1)).assertFalse();
      // Nothing left to fire — a second cancel() is a harmless no-op (idempotent).
      scheduler.cancel();
      expect(fake.cancelledHandles).assertDeepEquals([1]);
      expect(fired).assertFalse();
    });

    it('request() after a fired callback schedules independently (debounce windows don\'t leak into each other)', 0, () => {
      const fake = new FakeScheduler();
      const scheduler = new NeuralRerankScheduler(fake, 200);
      let firstCalls = 0;
      let secondCalls = 0;
      scheduler.request(() => { firstCalls++; });
      fake.fire(1);
      expect(firstCalls).assertEqual(1);

      scheduler.request(() => { secondCalls++; });
      expect(fake.isPending(2)).assertTrue();
      fake.fire(2);
      expect(secondCalls).assertEqual(1);
      expect(firstCalls).assertEqual(1); // unchanged by the second window
    });
  });
}
