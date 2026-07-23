import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { BatchRow, FlatBatchLogits, NeuralModel, RowLogits } from '../../pinyin/NeuralScorer';

/**
 * Wraps a loaded MindSpore Lite Kit model as a NeuralModel (pinyin/NeuralScorer.ets's batch
 * inference abstraction). **Compile-only verified, not unit-tested** — real on-device inference
 * can't be exercised off-device (issue #20 phase 3; NeuralScorer.test.ets unit-tests the scoring
 * math this feeds, against a fake NeuralModel instead of this class).
 *
 * Model I/O contract (xupin/docs/issue-22-shape-fix.md §2's reconfirmed no-cache export shape —
 * the KV-cache graph is not used, per that report and spike-20-neural-ranking.md §4/§5a): three
 * inputs named `input_ids`, `attention_mask`, `position_ids` (each `[batchSize, sequenceLength]`,
 * baked to a FIXED shape at conversion time — issue #22 D1, xupin/docs/issue-22-shape-fix.md §3),
 * one `logits` output (`[batchSize, sequenceLength, vocabSize]`). `batchSize`/`sequenceLength`
 * are derived from the `rows` this is called with (see predict()) rather than imported as
 * separate constants — they must equal whatever NeuralScorer.ets's caller built the rows with,
 * which itself must equal the converted .ms file's baked shape (xupin/docs/issue-22-shape-fix.md
 * §5); a mismatch surfaces naturally as a MindSpore Lite Kit tensor-size error from setData(),
 * same as the bug #22 exists to fix.
 *
 * Issue #22 D2/D9: one `predict()` call handles the whole batch (was one call per candidate
 * pre-#22), and reads `logits` directly off the returned `Float32Array` via a thin per-row
 * accessor (RowLogits) instead of materializing a `number[][][]` — at `[9, 20, 21128]` that
 * would be ~15.2MB of nested-array allocation and element-by-element copying per keystroke.
 */
export class MindSporeNeuralModel implements NeuralModel {
  private readonly model: mindSporeLite.Model;

  constructor(model: mindSporeLite.Model) {
    this.model = model;
  }

  async predict(rows: BatchRow[]): Promise<RowLogits[]> {
    const batchSize = rows.length;
    const sequenceLength = batchSize > 0 ? rows[0].tokenIds.length : 0;

    const inputs = this.model.getInputs();
    for (let i = 0; i < inputs.length; i++) {
      const tensor = inputs[i];
      tensor.setData(encodeInts(valuesFor(tensor.name, rows, sequenceLength), tensor.dtype));
    }

    const outputs = await this.model.predict(inputs);
    // Single `logits` output per the no-cache export shape (see this file's doc) — the
    // KV-cache graph's extra present.N.{key,value} outputs don't apply here.
    const logitsTensor = outputs[0];
    const shape = logitsTensor.shape;
    const vocabSize = shape[shape.length - 1];
    const flat = new Float32Array(logitsTensor.getData());
    const expectedLength = batchSize * sequenceLength * vocabSize;
    if (flat.length !== expectedLength) {
      throw new Error('MindSporeNeuralModel: logits tensor "' + logitsTensor.name + '" dataSize ' +
        flat.length + ' does not match batch=' + batchSize + ' x seq=' + sequenceLength +
        ' x vocab=' + vocabSize + ' (=' + expectedLength + ') for shape [' + shape.join(',') + ']');
    }

    const batch = new FlatBatchLogits(flat, sequenceLength, vocabSize);
    const rowViews: RowLogits[] = [];
    for (let r = 0; r < batchSize; r++) {
      rowViews.push(batch.rowAt(r));
    }
    return rowViews;
  }
}

function valuesFor(inputName: string, rows: BatchRow[], sequenceLength: number): number[] {
  if (inputName === 'input_ids') {
    const values: number[] = [];
    for (let r = 0; r < rows.length; r++) {
      const tokenIds = rows[r].tokenIds;
      for (let i = 0; i < tokenIds.length; i++) {
        values.push(tokenIds[i]);
      }
    }
    return values;
  }
  if (inputName === 'attention_mask') {
    const values: number[] = [];
    for (let r = 0; r < rows.length; r++) {
      const attentionMask = rows[r].attentionMask;
      for (let i = 0; i < attentionMask.length; i++) {
        values.push(attentionMask[i]);
      }
    }
    return values;
  }
  if (inputName === 'position_ids') {
    // Always 0..sequenceLength-1 for every row, never told explicitly — real tokens are always
    // front-loaded by buildBatchRow()'s right-padding (see BatchRow's doc), so the physical
    // array index already is each real token's true position.
    const values: number[] = [];
    for (let r = 0; r < rows.length; r++) {
      for (let i = 0; i < sequenceLength; i++) {
        values.push(i);
      }
    }
    return values;
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
