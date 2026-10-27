import {mkdir, readdir, copyFile, rm} from 'node:fs/promises';
import {join} from 'node:path';

const source = join(process.cwd(), 'node_modules', 'onnxruntime-web', 'dist');
const destination = join(process.cwd(), 'public', 'ort');
await rm(destination, {recursive: true, force: true});
await mkdir(destination, {recursive: true});
const available = new Set(await readdir(source));
const files = [
  'ort-wasm-simd-threaded.mjs',
  'ort-wasm-simd-threaded.wasm',
  'ort-wasm-simd-threaded.jsep.mjs',
  'ort-wasm-simd-threaded.jsep.wasm'
]
  .filter(name => available.has(name));
await Promise.all(files.map(name => copyFile(join(source, name), join(destination, name))));
console.log(`Copied ${files.length} ONNX Runtime WebAssembly assets.`);
