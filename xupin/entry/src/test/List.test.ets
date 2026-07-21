import localUnitTest from './LocalUnit.test';
import segmenterTest from './pinyin/Segmenter.test';
import dictionaryTest from './pinyin/Dictionary.test';
import bigramModelTest from './pinyin/BigramModel.test';
import candidateScorerTest from './pinyin/CandidateScorer.test';
import candidateGeneratorTest from './pinyin/CandidateGenerator.test';
import compositionStateTest from './InputMethodExtensionAbility/model/CompositionState.test';

export default function testsuite() {
  localUnitTest();
  segmenterTest();
  dictionaryTest();
  bigramModelTest();
  candidateScorerTest();
  candidateGeneratorTest();
  compositionStateTest();
}