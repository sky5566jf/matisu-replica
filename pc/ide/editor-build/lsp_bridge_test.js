// lsp_bridge_test.js — 端到端验证 /ws/lsp 桥 + lua-language-server + matisu meta
// 前置：node server.js <port>（server 自动在 scripts/ 生成 .luarc.json 挂载 meta）
// 用法：node lsp_bridge_test.js [port]
const port = process.argv[2] || '5599';

async function main() {
  const info = await (await fetch(`http://127.0.0.1:${port}/api/lsp`)).json();
  if (!info.ok) { console.error('FAIL: /api/lsp 报不可用'); process.exit(1); }
  console.log('PASS /api/lsp: rootUri =', info.rootUri);

  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/lsp`);
  let seq = 0;
  const pending = new Map();
  const send = (obj) => ws.send(JSON.stringify(obj));
  const req = (method, params) => new Promise((res, rej) => {
    const id = ++seq;
    pending.set(id, { res, rej });
    send({ jsonrpc: '2.0', id, method, params });
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); rej(new Error('timeout ' + method)); } }, 25000);
  });
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  let diagnostics = null;

  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
      const p = pending.get(msg.id);
      if (p) { pending.delete(msg.id); msg.error ? p.rej(new Error(JSON.stringify(msg.error))) : p.res(msg.result); }
      return;
    }
    if (msg.id !== undefined && msg.method) {
      send({ jsonrpc: '2.0', id: msg.id, result: msg.method === 'workspace/configuration' ? (msg.params.items || []).map(() => null) : null });
      return;
    }
    if (msg.method === 'textDocument/publishDiagnostics') {
      console.log('  << publishDiagnostics ' + decodeURIComponent(msg.params.uri.split('/').pop()) + ' [' + (msg.params.diagnostics || []).map((d) => d.code).join(',') + ']');
      diagnostics = msg.params;
    }
  };
  const fail = (m) => { console.error('FAIL: ' + m); process.exit(1); };

  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('WS 连接失败')); });
  try {
    const init = await req('initialize', {
      processId: null, rootUri: info.rootUri,
      capabilities: {
        textDocument: {
          synchronization: { didSave: false, dynamicRegistration: false },
          completion: { completionItem: { snippetSupport: false } }, hover: {}, publishDiagnostics: {},
        },
        workspace: { configuration: false },
      },
      clientInfo: { name: 'bridge-test' },
    });
    console.log('PASS initialize:', init.serverInfo && init.serverInfo.name);
    send({ jsonrpc: '2.0', method: 'initialized', params: {} });

    const uri = info.rootUri + 'test.lua';
    const text = 'local function foo()\n  findC\nend\n';
    send({ jsonrpc: '2.0', method: 'textDocument/didOpen', params: { textDocument: { uri, languageId: 'lua', version: 1, text } } });
    await wait(5000);

    // 1) 前缀补全：findC 应命中 findColor/findColorT/findMultiColor*
    const comp = await req('textDocument/completion', { textDocument: { uri }, position: { line: 1, character: 7 } });
    const items = Array.isArray(comp) ? comp : (comp && comp.items) || [];
    const labels = items.map((i) => i.label);
    const hits = labels.filter((l) => /^find/i.test(l));
    console.log('find* 补全 =', hits.join(', ') || '(无)');
    if (!hits.some((l) => /^findColor\(/.test(l))) fail('补全未命中 findColor（meta/.luarc.json 未生效）');
    console.log('PASS completion: findColor* 已补全');

    // 2) 悬浮：findColor 应有中文文档
    send({ jsonrpc: '2.0', method: 'textDocument/didChange', params: { textDocument: { uri, version: 2 }, contentChanges: [{ text: 'findColor(0,0,100,100,"FFFFFF")\n' }] } });
    await wait(1500);
    const hov = await req('textDocument/hover', { textDocument: { uri }, position: { line: 0, character: 3 } });
    const txt = hov && hov.contents ? (typeof hov.contents === 'string' ? hov.contents : (hov.contents.value || '')) : '';
    console.log('hover =', txt.replace(/\n/g, ' | ').slice(0, 150));
    if (!/findColor/.test(txt) || !/多点找色/.test(txt)) fail('hover 缺签名或中文文档');
    console.log('PASS hover: 签名+文档');

    // 3) 诊断：未定义全局应报 undefined-global（语义诊断在 workspace 索引后有延迟，轮询 15s）
    send({ jsonrpc: '2.0', method: 'textDocument/didChange', params: { textDocument: { uri, version: 3 }, contentChanges: [{ text: 'zzzNotDefined()\n' }] } });
    const normUri = (u) => { try { return decodeURIComponent(new URL(u).pathname).toLowerCase(); } catch (_) { return decodeURIComponent(String(u)).toLowerCase(); } };
    const hasUndef = () => !!(diagnostics && normUri(diagnostics.uri) === normUri(uri) && (diagnostics.diagnostics || []).some((d) => d.code === 'undefined-global'));
    for (let i = 0; i < 15 && !hasUndef(); i++) await wait(1000);
    const ds = diagnostics && normUri(diagnostics.uri) === normUri(uri) ? diagnostics.diagnostics : [];
    console.log('diagnostics =', ds.map((d) => d.message.split('\n')[0]).join(' ; ') || '(无)');
    if (!hasUndef()) fail('未收到 undefined-global 诊断');
    console.log('PASS diagnostics: 推送链路工作');

    console.log('\n=== LSP 桥端到端 4/4 PASS ===');
    process.exit(0);
  } catch (e) { fail(e.message); }
}
main().catch((e) => { console.error('FAIL: ' + e.message); process.exit(1); });
