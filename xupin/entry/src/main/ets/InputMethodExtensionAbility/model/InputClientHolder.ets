import { inputMethodEngine } from '@kit.IMEKit';

class InputClientHolder {
  private client: inputMethodEngine.InputClient | undefined = undefined;

  setClient(client: inputMethodEngine.InputClient | undefined): void {
    this.client = client;
  }

  getClient(): inputMethodEngine.InputClient | undefined {
    return this.client;
  }
}

export const inputClientHolder: InputClientHolder = new InputClientHolder();
