import localUnitTest from './LocalUnit.test';
import segmenterTest from './pinyin/Segmenter.test';
import dictionaryTest from './pinyin/Dictionary.test';
import candidateGeneratorTest from './pinyin/CandidateGenerator.test';
import compositionStateTest from './InputMethodExtensionAbility/model/CompositionState.test';

export default function testsuite() {
  localUnitTest();
  segmenterTest();
  dictionaryTest();
  candidateGeneratorTest();
  compositionStateTest();
}