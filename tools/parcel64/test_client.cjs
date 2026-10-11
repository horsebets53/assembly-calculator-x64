// Standard-library-only client tests with a simulated network, not browser E2E.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8').split('<script>')[1].split('</script>')[0];
const CHUNK = 64 * 1024 * 1024;
function node() {
  const children = new Map();
  return {
    value: 'test', style: {}, classList: {toggle() {}, add() {}, remove() {}},
    textContent: '', disabled: false, append() {}, remove() {}, addEventListener() {}, setAttribute() {},
    querySelector(key) {if (!children.has(key)) children.set(key, node()); return children.get(key);}
  };
}
async function run(mode) {
  const elements = new Map(), requests = [];
  let offset = 0, created = 0, first = true, failing = mode === 'manual-resume';
  const context = {
    console, Blob, AbortSignal,
    sessionStorage: {getItem: () => '', setItem() {}}, navigator: {},
    document: {getElementById(id) {if (!elements.has(id)) elements.set(id, node()); return elements.get(id);}, createElement: node},
    window: {addEventListener() {}}, setTimeout(fn) {queueMicrotask(fn);},
    fetch: async (url, options) => {
      let data;
      if (url === '/api/config') data = {limit: 500*1024*1024, chunk: CHUNK};
      else if (url === '/api/uploads' && options.method === 'POST') {created++; data = {id: 'test', offset: 0};}
      else if (url.endsWith('/complete')) data = {sha256: '0'.repeat(64)};
      else data = {offset};
      return {ok: true, status: 200, json: async () => data};
    },
    XMLHttpRequest: class {
      headers = {}; upload = {};
      open() {} setRequestHeader(k,v) {this.headers[k] = v;}
      send(blob) {
        const start = Number(this.headers['X-Offset']);
        requests.push({offset: start, size: blob.size});
        assert.equal(start, offset);
        assert(blob.size <= CHUNK);
        if (start === CHUNK && failing) return queueMicrotask(() => this.onerror());
        offset += blob.size;
        if (first && mode === 'lost-ack') {first = false; return queueMicrotask(() => this.onerror());}
        this.status = 200; this.responseText = JSON.stringify({offset});
        queueMicrotask(() => this.onload());
      }
      abort() {this.onabort();}
    }
  };
  vm.createContext(context); vm.runInContext(source, context);
  await vm.runInContext('connect()', context);
  const unit = new Blob([new Uint8Array(1024*1024)]);
  context.file = Object.assign(new Blob([...Array(64).fill(unit), new Uint8Array(3)]), {name: 'test.bin'});
  vm.runInContext('addFiles([file])', context);
  await elements.get('send').onclick();
  if (mode === 'manual-resume') {
    assert.equal(vm.runInContext('items[0].state', context), 'error');
    assert.equal(offset, CHUNK);
    failing = false;
    vm.runInContext("items[0].node.querySelector('.cancel').onclick()", context);
    await elements.get('send').onclick();
  }
  assert.equal(vm.runInContext('items[0].state', context), 'done');
  assert.equal(created, 1, 'retry must reuse the session');
  assert.equal(offset, CHUNK + 3);
  assert.equal(requests.filter(r => r.offset === 0).length, 1, 'acknowledged chunk must not be resent');
  assert.equal(requests.at(-1).size, 3, 'unaligned final chunk');
  console.log('ok:', mode);
}
(async () => {for (const mode of ['normal', 'lost-ack', 'manual-resume']) await run(mode);})()
  .catch(error => {console.error(error); process.exitCode = 1;});
