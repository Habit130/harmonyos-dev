import { NeuralModel } from '../../pinyin/NeuralScorer';

class NeuralModelHolder {
  private model: NeuralModel | undefined = undefined;

  setModel(model: NeuralModel): void {
    this.model = model;
  }

  getModel(): NeuralModel | undefined {
    return this.model;
  }
}

export const neuralModelHolder: NeuralModelHolder = new NeuralModelHolder();
