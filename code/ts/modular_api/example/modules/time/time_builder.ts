import { ModuleBuilder } from '../../../src/index';
import { CurrentTimeInput, CurrentTimeOutput, CurrentTime } from './usecases/current_time';

export function buildTimeModule(m: ModuleBuilder): void {
  m.usecase('current-time', CurrentTime.fromJson, {
    inputClass: CurrentTimeInput,
    outputClass: CurrentTimeOutput,
    method: 'GET',
  });
}
