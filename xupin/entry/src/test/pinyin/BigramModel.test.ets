import { describe, it, expect } from '@ohos/hypium';
import { BigramModel } from '../../main/ets/pinyin/BigramModel';

const FIXTURE = [
  '打\t篮球\t50',
  '打\t电话\t10',
  '接\t电话\t80',
].join('\n');

export default function bigramModelTest() {
  describe('BigramModelTest', () => {
    it('reports the observed count for a seen (prevWord, word) pair', 0, () => {
      const model = BigramModel.parse(FIXTURE);
      expect(model.count('打', '篮球')).assertEqual(50);
      expect(model.count('打', '电话')).assertEqual(10);
      expect(model.count('接', '电话')).assertEqual(80);
    });

    it('returns 0 for an unseen successor or an unknown preceding word', 0, () => {
      const model = BigramModel.parse(FIXTURE);
      expect(model.count('打', '足球')).assertEqual(0); // known prev, never-seen successor
      expect(model.count('未知', '电话')).assertEqual(0); // unknown prev word entirely
    });

    it('parses an empty string into a model with no evidence', 0, () => {
      const model = BigramModel.parse('');
      expect(model.count('打', '篮球')).assertEqual(0);
    });

    it('skips malformed lines instead of failing', 0, () => {
      // A 2-column line (missing count) and a blank line must be ignored, not throw.
      const model = BigramModel.parse('打\t篮球\t50\n打\t电话\n\n接\t电话\t80');
      expect(model.count('打', '篮球')).assertEqual(50);
      expect(model.count('打', '电话')).assertEqual(0); // the malformed line was dropped
      expect(model.count('接', '电话')).assertEqual(80);
    });
  });
}
