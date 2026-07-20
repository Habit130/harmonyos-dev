import { InputMethodExtensionAbility, inputMethodEngine } from '@kit.IMEKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { inputClientHolder } from './model/InputClientHolder';
import { dictionaryHolder } from './model/DictionaryHolder';
import { Dictionary } from '../pinyin/Dictionary';

const DOMAIN = 0x0000;
const TAG = 'XupinIME';
const DICT_RAWFILE_PATH = 'dict/words.dict.tsv';

let panel: inputMethodEngine.Panel | undefined = undefined;

export default class InputMethodService extends InputMethodExtensionAbility {
  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'onCreate want: %{public}s', want.abilityName ?? '');
    this.registerListeners();
    this.createPanel();
    this.loadDictionary();
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
}
