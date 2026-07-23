import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { NeuralModel } from '../../pinyin/NeuralScorer';

/**
 * Wraps a loaded MindSpore Lite Kit model as a NeuralModel (pinyin/NeuralScorer.ets's
 * inference abstraction). **Compile-only verified, not unit-tested or device-tested** — real
 * on-device inference can't be exercised off-device (issue #20 phase 3; NeuralScorer.test.ets
 * unit-tests the scoring math this feeds, against a fake NeuralModel instead of this class).
 *
 * Model I/O contract assumed here (xupin/docs/spike-20-neural-ranking.md §3's confirmed
 * no-cache export shape — the KV-cache graph is not used, per that report's §4/§5a): three
 * inputs named `input_ids`, `attention_mask`, `position_ids` (each `[1, sequenceLength]`), one
 * `logits` output (`[1, sequenceLength, vocabSize]`). The spike confirmed conversion and
 * execution succeed despite MindSpore Lite Kit's own docs claiming no op supports int64 input
 * (see that report's §5/§5a) but did not specifically inspect whether the *converted* `.ms`
 * file's input tensors end up declared int32 or int64 — this reads each input's actual
 * `dtype` at runtime and encodes accordingly rather than assuming one or the other.
 */
export class MindSporeNeuralModel implements NeuralModel {
  private readonly model: mindSporeLite.Model;

  constructor(model: mindSporeLite.Model) {
    this.model = model;
  }

  async predict(tokenIds: number[]): Promise<number[][]> {
    const sequenceLength = tokenIds.length;
    const inputs = this.model.getInputs();
    for (let i = 0; i < inputs.length; i++) {
      const tensor = inputs[i];
      tensor.setData(encodeInts(valuesFor(tensor.name, tokenIds, sequenceLength), tensor.dtype));
    }

    const outputs = await this.model.predict(inputs);
    // Single `logits` output per the no-cache export shape (see this file's doc) — the
    // KV-cache graph's extra present.N.{key,value} outputs don't apply here.
    const logitsTensor = outputs[0];
    const vocabSize = logitsTensor.shape[logitsTensor.shape.length - 1];
    const flat = new Float32Array(logitsTensor.getData());
    const logits: number[][] = [];
    for (let position = 0; position < sequenceLength; position++) {
      const row: number[] = [];
      const base = position * vocabSize;
      for (let v = 0; v < vocabSize; v++) {
        row.push(flat[base + v]);
      }
      logits.push(row);
    }
    return logits;
  }
}

function valuesFor(inputName: string, tokenIds: number[], sequenceLength: number): number[] {
  if (inputName === 'input_ids') {
    return tokenIds;
  }
  if (inputName === 'attention_mask') {
    // Every call sends an exact-length sequence, no padding — an all-ones mask.
    return new Array<number>(sequenceLength).fill(1);
  }
  if (inputName === 'position_ids') {
    const ids: number[] = [];
    for (let i = 0; i < sequenceLength; i++) {
      ids.push(i);
    }
    return ids;
  }
  throw new Error('MindSporeNeuralModel: unexpected model input "' + inputName + '"');
}

function encodeInts(values: number[], dtype: mindSporeLite.DataType): ArrayBuffer {
  if (dtype === mindSporeLite.DataType.NUMBER_TYPE_INT64) {
    // Token/position ids and the 0-or-1 mask are all small non-negative integers, so a
    // little-endian int64 is just the value in the low 32-bit word and zero in the high word.
    const buffer = new ArrayBuffer(values.length * 8);
    const view = new DataView(buffer);
    for (let i = 0; i < values.length; i++) {
      view.setUint32(i * 8, values[i], true);
      view.setUint32(i * 8 + 4, 0, true);
    }
    return buffer;
  }
  // Default: int32. Treated as the fallback rather than throwing on anything other than
  // int64, since the spike didn't confirm which dtype the converted .ms actually declares
  // (see this file's doc) — int32 is the more likely outcome given the conversion succeeded
  // at all despite the doc's int64 caveat.
  return new Int32Array(values).buffer;
}
