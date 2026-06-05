import { ModuleBuilder } from '../../../src/index';
import { HelloWorldInput, HelloWorldOutput, HelloWorld } from './usecases/hello_world';

export function buildGreetingsModule(m: ModuleBuilder): void {
  m.usecase('hello-world', HelloWorld.fromJson, {
    inputClass: HelloWorldInput,
    outputClass: HelloWorldOutput,
  });
}
