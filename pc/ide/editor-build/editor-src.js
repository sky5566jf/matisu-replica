// MatisuAuto IDE 编辑器：CodeMirror 6 + 极简 LSP 客户端（WebSocket 桥到 lua-language-server）
import { EditorState } from '@codemirror/state';
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { StreamLanguage, syntaxHighlighting, defaultHighlightStyle, HighlightStyle, indentOnInput, bracketMatching } from '@codemirror/language';
import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from '@codemirror/autocomplete';
import { linter, lintGutter, setDiagnostics } from '@codemirror/lint';
import { hoverTooltip } from '@codemirror/view';
import { lua } from '@codemirror/legacy-modes/mode/lua';
import { tags as t } from '@lezer/highlight';

// ---------------- 极简 LSP 客户端（JSON-RPC over WebSocket） ----------------
class LspClient {
  constructor(url) {
    this.url = url;
    this.seq = 0;
    this.pending = new Map();   // id -> {resolve, reject}
    this.handlers = new Map();  // method -> cb
    this.ready = false;
    this.rootUri = null;
  }
  connect(rootUri) {
    this.rootUri = rootUri;
    return new Promise((resolve, reject) => {
      let settled = false;
      const ws = new WebSocket(this.url);
      this.ws = ws;
      ws.onmessage = (ev) => this._onMsg(ev.data);
      ws.onclose = () => { this.ready = false; this._flushErr(new Error('LSP 连接断开')); };
      ws.onerror = () => { if (!settled) { settled = true; reject(new Error('LSP WebSocket 连接失败')); } };
      ws.onopen = () => {
        // 注意：不传 initializationOptions——客户端 settings 会覆盖服务端 scripts/.luarc.json
        // （其中 workspace.library 指向 meta 注解；客户端传值反而使其失效），配置一律走 .luarc.json
        this.request('initialize', {
          processId: null,
          rootUri,
          capabilities: {
            textDocument: {
              synchronization: { didSave: false, dynamicRegistration: false },
              completion: { completionItem: { snippetSupport: false, documentationFormat: ['plaintext', 'markdown'] } },
              hover: { contentFormat: ['plaintext', 'markdown'] },
              publishDiagnostics: {},
            },
            workspace: { configuration: false },
          },
          clientInfo: { name: 'MatisuAuto-IDE' },
        }).then((r) => {
          this.notify('initialized', {});
          this.ready = true;
          settled = true;
          resolve(r);
        }).catch((e) => { settled = true; reject(e); });
      };
    });
  }
  _flushErr(e) { for (const p of this.pending.values()) p.reject(e); this.pending.clear(); }
  _onMsg(data) {
    let msg;
    try { msg = JSON.parse(data); } catch (_) { return; }
    if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
      const p = this.pending.get(msg.id);
      if (p) { this.pending.delete(msg.id); msg.error ? p.reject(new Error(msg.error.message || 'LSP error')) : p.resolve(msg.result); }
      return;
    }
    if (msg.id !== undefined && msg.method) {
      // 服务器请求（如 workspace/configuration）——统一空响应
      this._send({ jsonrpc: '2.0', id: msg.id, result: msg.method === 'workspace/configuration' ? (msg.params.items || []).map(() => null) : null });
      return;
    }
    const cb = this.handlers.get(msg.method);
    if (cb) cb(msg.params);
  }
  _send(obj) { if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(obj)); }
  request(method, params) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this._send({ jsonrpc: '2.0', id, method, params });
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error('LSP 超时: ' + method)); } }, 15000);
    });
  }
  notify(method, params) { this._send({ jsonrpc: '2.0', method, params }); }
  on(method, cb) { this.handlers.set(method, cb); }
}

// ---------------- 主题 ----------------
const darkHl = HighlightStyle.define([
  { tag: t.keyword, color: '#c792ea' },
  { tag: [t.string, t.special(t.string)], color: '#c3e88d' },
  { tag: [t.number, t.bool, t.null], color: '#f78c6c' },
  { tag: t.comment, color: '#546e7a', fontStyle: 'italic' },
  { tag: t.function(t.variableName), color: '#82aaff' },
  { tag: t.standard(t.variableName), color: '#89ddff' },
  { tag: t.operator, color: '#89ddff' },
]);

const darkTheme = EditorView.theme({
  '&': { backgroundColor: '#14161a', color: '#d6dbe2', height: '100%', fontSize: '13px' },
  '.cm-content': { fontFamily: "'Cascadia Code', Consolas, 'Courier New', monospace", caretColor: '#7aa2f7', padding: '6px 0' },
  '.cm-gutters': { backgroundColor: '#101216', color: '#4b5263', border: 'none', borderRight: '1px solid #23262d' },
  '.cm-activeLine': { backgroundColor: '#1b1e25' },
  '.cm-activeLineGutter': { backgroundColor: '#1b1e25', color: '#8b93a5' },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground': { backgroundColor: '#26456b' },
  '.cm-cursor': { borderLeftColor: '#7aa2f7' },
  '.cm-tooltip': { backgroundColor: '#1c1f26', border: '1px solid #333a45', color: '#d6dbe2' },
  '.cm-tooltip-autocomplete ul li[aria-selected]': { backgroundColor: '#26456b', color: '#fff' },
  '.cm-panels': { backgroundColor: '#1c1f26', color: '#d6dbe2' },
  '.cm-lintRange-error': { textDecoration: 'underline wavy #f44747 1px' },
  '.cm-lintRange-warning': { textDecoration: 'underline wavy #cca700 1px' },
}, { dark: true });

// ---------------- LSP <-> CM6 桥 ----------------
function posToOffset(doc, pos) {
  const line = doc.line(Math.min(pos.line + 1, doc.lines));
  return Math.min(line.from + pos.character, line.to);
}
function offsetToPos(doc, off) {
  const line = doc.lineAt(off);
  return { line: line.number - 1, character: off - line.from };
}

function lspCompletionSource(lsp, getUri) {
  return async (ctx) => {
    if (!lsp || !lsp.ready) return null;
    const pos = offsetToPos(ctx.state.doc, ctx.pos);
    try {
      const r = await lsp.request('textDocument/completion', {
        textDocument: { uri: getUri() }, position: pos,
        context: { triggerKind: ctx.explicit ? 1 : 2 },
      });
      if (!r) return null;
      const items = Array.isArray(r) ? r : (r.items || []);
      const word = ctx.matchBefore(/[\w.]*/);
      const from = word ? word.from : ctx.pos;
      return {
        from,
        options: items.slice(0, 200).map((it) => ({
          label: it.label,
          type: ({ 3: 'function', 6: 'variable', 5: 'property', 10: 'property', 7: 'class', 9: 'namespace', 14: 'keyword', 1: 'text', 21: 'constant' })[it.kind] || 'text',
          detail: it.detail ? String(it.detail).slice(0, 80) : undefined,
          info: it.documentation ? (typeof it.documentation === 'string' ? it.documentation : (it.documentation.value || '')) : undefined,
          apply: it.insertText || it.label,
        })),
        validFor: /^[\w.]*$/,
      };
    } catch (_) { return null; }
  };
}

function lspHover(getLsp, getUri) {
  return hoverTooltip(async (view, pos) => {
    const lsp = getLsp();
    if (!lsp || !lsp.ready) return null;
    const p = offsetToPos(view.state.doc, pos);
    try {
      const r = await lsp.request('textDocument/hover', { textDocument: { uri: getUri() }, position: p });
      if (!r || !r.contents) return null;
      const c = r.contents;
      let text = '';
      if (typeof c === 'string') text = c;
      else if (Array.isArray(c)) text = c.map((x) => (typeof x === 'string' ? x : x.value || '')).join('\n');
      else text = c.value || '';
      if (!text.trim()) return null;
      return {
        pos, end: pos,
        above: true,
        create() {
          const dom = document.createElement('div');
          dom.style.cssText = 'max-width:520px;padding:6px 10px;font-size:12px;white-space:pre-wrap;word-break:break-all;';
          dom.textContent = text.replace(/```lua/g, '').replace(/```/g, '').trim().slice(0, 1200);
          return { dom };
        },
      };
    } catch (_) { return null; }
  });
}

// ---------------- 对外工厂 ----------------
export function createEditor({ parent, doc, getUri, lspUrl, onChange }) {
  let lsp = null;
  let curUri = null;
  let changeTimer = null;

  const lspLint = linter(() => [], { delay: 0 }); // 诊断由 publishDiagnostics 推送注入

  const view = new EditorView({
    parent,
    state: EditorState.create({
      doc: doc || '',
      extensions: [
        lineNumbers(), highlightActiveLine(), highlightActiveLineGutter(), drawSelection(),
        history(), indentOnInput(), bracketMatching(), closeBrackets(),
        keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap, ...completionKeymap, indentWithTab]),
        StreamLanguage.define(lua),
        syntaxHighlighting(darkHl, { fallback: true }),
        darkTheme,
        autocompletion({ override: [(c) => lspCompletionSource(lsp, () => curUri)(c)], activateOnTyping: true, maxRenderedOptions: 60 }),
        lspHover(() => lsp, () => curUri),
        lspLint, lintGutter(),
        EditorView.updateListener.of((u) => {
          if (u.docChanged) {
            if (onChange) onChange(u.state.doc.toString());
            scheduleSync();
          }
        }),
      ],
    }),
  });

  function scheduleSync() {
    if (!lsp || !lsp.ready || !curUri) return;
    clearTimeout(changeTimer);
    changeTimer = setTimeout(() => {
      lsp.notify('textDocument/didChange', {
        textDocument: { uri: curUri, version: Date.now() },
        contentChanges: [{ text: view.state.doc.toString() }],
      });
    }, 250);
  }

  function openDoc(uri, text) {
    if (!lsp || !lsp.ready) { curUri = uri; return; }
    if (curUri && curUri !== uri) lsp.notify('textDocument/didClose', { textDocument: { uri: curUri } });
    curUri = uri;
    lsp.notify('textDocument/didOpen', {
      textDocument: { uri, languageId: 'lua', version: Date.now(), text },
    });
  }

  // 诊断推送 → CM6 lint（LLS 会把 URI 规范化：盘符小写、冒号编成 %3A，比较前须归一化）
  function bindDiagnostics() {
    const normUri = (u) => {
      try { return decodeURIComponent(new URL(u).pathname).toLowerCase(); } catch (_) { return decodeURIComponent(String(u)).toLowerCase(); }
    };
    lsp.on('textDocument/publishDiagnostics', (p) => {
      if (!p || !curUri || normUri(p.uri) !== normUri(curUri)) return;
      const ds = (p.diagnostics || []).map((d) => ({
        from: posToOffset(view.state.doc, d.range.start),
        to: posToOffset(view.state.doc, d.range.end),
        severity: d.severity === 1 ? 'error' : (d.severity === 2 ? 'warning' : 'info'),
        message: d.message,
        source: d.source || 'lua-ls',
      }));
      view.dispatch(setDiagnostics(view.state, ds));
    });
  }

  return {
    view,
    getDoc: () => view.state.doc.toString(),
    setDoc(text, uri) {
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
      openDoc(uri, text);
    },
    async connectLsp(rootUri) {
      lsp = new LspClient(lspUrl);
      await lsp.connect(rootUri);
      bindDiagnostics();
      // 无打开标签页时给默认文档（否则 curUri=null，补全/hover/诊断全部失效）
      if (!curUri) curUri = (rootUri.endsWith('/') ? rootUri : rootUri + '/') + 'untitled.lua';
      openDoc(curUri, view.state.doc.toString());
    },
    get lspReady() { return !!(lsp && lsp.ready); },
  };
}
