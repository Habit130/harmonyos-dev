import { InputMethodExtensionAbility, inputMethodEngine } from '@kit.IMEKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { inputClientHolder } from './model/InputClientHolder';
import { dictionaryHolder } from './model/DictionaryHolder';
import { Dictionary } from '../pinyin/Dictionary';
import { tokenizerHolder } from './model/TokenizerHolder';
import { neuralModelHolder } from './model/NeuralModelHolder';
import { Tokenizer } from '../pinyin/Tokenizer';
import { MindSporeNeuralModel } from './model/MindSporeNeuralModel';

const DOMAIN = 0x0000;
const TAG = 'XupinIME';
const DICT_RAWFILE_PATH = 'dict/words.dict.tsv';
// Neither asset is bundled yet (issue #20 phase-1 spike found the checkpoint's license isn't
// actually confirmed — xupin/docs/spike-20-neural-ranking.md's "License status" section — so
// no checkpoint-derived data ships in this repo pending that decision). Both loads below fail
// gracefully (same non-fatal try/catch pattern as loadDictionary()) until someone adds the real
// files at these paths, at which point neural re-ranking activates with no code change needed.
const NEURAL_VOCAB_RAWFILE_PATH = 'model/vocab.txt';
const NEURAL_MODEL_RAWFILE_PATH = 'model/neural_scorer.ms';

// Issue #24 phase 2: `msContext.cpu = {}` alone leaves every runtime knob at MindSpore Lite
// Kit's default (threadNum=2, threadAffinityMode=NO_AFFINITIES, precisionMode='enforce_fp32' —
// `~/Documents/HarmonyOSDocs/.../apis-mindspore-lite-kit/js-apis-mindSporeLite.md:511-514`),
// which phase 0's real-device measurement (xupin/docs/issue-24-phase0-instrumentation.md) showed
// costs ~735-765ms per predict() call, ~98% of it inside predict() itself — these three knobs are
// the no-reconversion, no-redeploy lever on that. Values match the official MindSpore Lite ArkTS
// sample's own explicit settings (docs/harmonyos-guides/AI/MindSpore Lite Kit（昇思推理框架服务）/
// 使用MindSpore Lite实现图像分类（ArkTS）.md:83-89).
//
// precisionMode reverted to 'enforce_fp32' (2026-07-24): real-device testing after this phase's
// first commit reported neural ranking looked completely inactive (no style/reorder at all, "like
// a generic IME") — exactly the symptom of loadNeuralModel() failing silently (its .catch() only
// hilog.warns, see below) if this checkpoint's chip doesn't support 'preferred_fp16'
// ("preferred" is not "guaranteed", per that doc line). This was the one revert path issue #24
// itself pre-authorized independently of threadNum/threadAffinityMode
// (xupin/docs/issue-24-phase2-runtime-params.md item 2) — reverted first as the leading, cheap,
// already-approved suspect; still needs a hilog-confirmed root cause (see that doc's "回退+复测"
// section) before this note can be trusted as the actual explanation rather than just the fix.
const NEURAL_THREAD_NUM: number = 4;
const NEURAL_THREAD_AFFINITY_MODE: mindSporeLite.ThreadAffinityMode = mindSporeLite.ThreadAffinityMode.BIG_CORES_FIRST;
const NEURAL_PRECISION_MODE: string = 'enforce_fp32';

let panel: inputMethodEngine.Panel | undefined = undefined;

export default class InputMethodService extends InputMethodExtensionAbility {
  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'onCreate want: %{public}s', want.abilityName ?? '');
    this.registerListeners();
    this.createPanel();
    this.loadDictionary();
    this.loadTokenizer();
    this.loadNeuralModel();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    if (panel) {
      inputMethodEngine.getInputMethodAbility().destroyPanel(panel).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'destroyPanel failed: %{public}d %{public}s', err.code, err.message);
      });
    }
  }

  private registerListeners(): void {
    inputMethodEngine.getInputMethodAbility().on('inputStart',
      (kbController: inputMethodEngine.KeyboardController, client: inputMethodEngine.InputClient) => {
        hilog.info(DOMAIN, TAG, 'inputStart: bound to a text field');
        inputClientHolder.setClient(client);
        // Signals the panel (Index.ets) to reset its composition buffer/candidates/history
        // for the newly bound field — see Index.ets's compositionResetSeq for why AppStorage
        // is the bridge. Key literal must match the one Index.ets links to.
        const seq = AppStorage.get<number>('xupinCompositionResetSeq') ?? 0;
        AppStorage.setOrCreate('xupinCompositionResetSeq', seq + 1);
      });
    inputMethodEngine.getInputMethodAbility().on('inputStop', () => {
      hilog.info(DOMAIN, TAG, 'inputStop: unbound from text field');
      inputClientHolder.setClient(undefined);
    });
  }

  private createPanel(): void {
    if (!this.context) {
      hilog.error(DOMAIN, TAG, 'createPanel: extension context missing');
      return;
    }
    const panelInfo: inputMethodEngine.PanelInfo = {
      type: inputMethodEngine.PanelType.SOFT_KEYBOARD,
      flag: inputMethodEngine.PanelFlag.FLG_FIXED
    };
    inputMethodEngine.getInputMethodAbility().createPanel(this.context, panelInfo)
      .then((createdPanel: inputMethodEngine.Panel) => {
        panel = createdPanel;
        const dis = display.getDefaultDisplaySync();
        const panelHeight = Math.floor(dis.height * 0.38);
        createdPanel.resize(dis.width, panelHeight)
          .then(() => createdPanel.setUiContent('InputMethodExtensionAbility/pages/Index'))
          .then(() => hilog.info(DOMAIN, TAG, 'panel content loaded'))
          .catch((err: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'resize/setUiContent failed: %{public}d %{public}s', err.code, err.message);
          });
      })
      .catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'createPanel failed: %{public}d %{public}s', err.code, err.message);
      });
  }

  private loadDictionary(): void {
    if (!this.context) {
      hilog.error(DOMAIN, TAG, 'loadDictionary: extension context missing');
      return;
    }
    try {
      const bytes = this.context.resourceManager.getRawFileContentSync(DICT_RAWFILE_PATH);
      const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
      dictionaryHolder.setDictionary(Dictionary.parse(text));
      hilog.info(DOMAIN, TAG, 'dictionary loaded');
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadDictionary failed: %{public}d %{public}s', error.code, error.message);
    }
  }

  // Non-fatal like loadDictionary(): a missing/failed-to-parse vocab just leaves neural
  // ranking disabled (NeuralScorer only ever gets constructed once both this and the model
  // below are present — see Index.ets's refreshCandidates()), same "asset absent, degrade,
  // don't crash" contract issue #20 specifies for the neural path generally.
  private loadTokenizer(): void {
    if (!this.context) {
      hilog.error(DOMAIN, TAG, 'loadTokenizer: extension context missing');
      return;
    }
    try {
      const bytes = this.context.resourceManager.getRawFileContentSync(NEURAL_VOCAB_RAWFILE_PATH);
      const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
      tokenizerHolder.setTokenizer(Tokenizer.parse(text));
      hilog.info(DOMAIN, TAG, 'neural tokenizer vocab loaded');
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'loadTokenizer failed, neural ranking stays disabled: %{public}d %{public}s',
        error.code, error.message);
    }
  }

  // Loaded async (unlike loadDictionary()'s sync read) — the model file is far larger
  // (tens-to-hundreds of MB even quantized, xupin/docs/spike-20-neural-ranking.md §5a) than
  // the dictionary TSV, so blocking the sync path here risks a visible stall. Mirrors the
  // official MindSpore Lite ArkTS sample's own load pattern (docs/harmonyos-guides/AI/
  // MindSpore Lite Kit（昇思推理框架服务）/使用MindSpore Lite实现图像分类（ArkTS）.md).
  private loadNeuralModel(): void {
    if (!this.context) {
      hilog.error(DOMAIN, TAG, 'loadNeuralModel: extension context missing');
      return;
    }
    this.context.resourceManager.getRawFileContent(NEURAL_MODEL_RAWFILE_PATH)
      .then((bytes: Uint8Array) => {
        const msContext: mindSporeLite.Context = {};
        msContext.target = ['cpu'];
        msContext.cpu = {};
        msContext.cpu.threadNum = NEURAL_THREAD_NUM;
        msContext.cpu.threadAffinityMode = NEURAL_THREAD_AFFINITY_MODE;
        // NEURAL_PRECISION_MODE is 'enforce_fp32' (reverted from 'preferred_fp16' — see that
        // constant's doc above). Kept as its own named constant, not inlined, in case a future
        // round narrows the earlier regression down to something else and fp16 gets retried.
        msContext.cpu.precisionMode = NEURAL_PRECISION_MODE;
        return mindSporeLite.loadModelFromBuffer(bytes.buffer.slice(0), msContext);
      })
      .then((model: mindSporeLite.Model) => {
        neuralModelHolder.setModel(new MindSporeNeuralModel(model));
        hilog.info(DOMAIN, TAG, 'neural model loaded');
      })
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'loadNeuralModel failed, neural ranking stays disabled: %{public}d %{public}s',
          err.code, err.message);
      });
  }
}
