import { webview } from '@kit.ArkWeb';

class MermaidScaleEntry {
  key: string;
  scale: number;

  constructor(key: string, scale: number) {
    this.key = key;
    this.scale = scale;
  }
}

class MermaidSizeBridge {
  private onSizeChange: (width: number, height: number) => void = (_width: number, _height: number): void => {};

  setOnSizeChange(callback: (width: number, height: number) => void): void {
    this.onSizeChange = callback;
  }

  reportSize(width: number, height: number): void {
    this.onSizeChange(width, height);
  }
}

@Component
export struct MermaidWebDiagram {
  @Prop
  @Watch('onSourceChanged')
  source: string = '';
  @Prop
  @Watch('onDiagramHeightChanged')
  diagramHeight: number = 260;
  @Prop
  @Watch('onFontScaleChanged')
  fontScale: number = 1;
  @State private measuredDiagramHeight: number = 260;

  private controller: webview.WebviewController = new webview.WebviewController();
  private sizeBridge: MermaidSizeBridge = new MermaidSizeBridge();

  aboutToAppear(): void {
    this.sizeBridge.setOnSizeChange((width: number, height: number): void => {
      this.updateMeasuredDiagramSize(width, height);
    });
    this.resetMeasuredDiagramHeight();
  }

  aboutToDisappear(): void {
    this.sizeBridge.setOnSizeChange((_width: number, _height: number): void => {});
  }

  private mermaidDataUrl(): string {
    return `data:text/html;charset=utf-8,${encodeURIComponent(this.mermaidHtml())}`;
  }

  private mermaidHtml(): string {
    const sourceText: string = this.escapeHtml(this.source);
    return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no" />
  <style>
    html, body {
      margin: 0;
      padding: 0;
      background: #FFFFFF;
      background-color: #FFFFFF !important;
      color: #0F172A;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      overflow: auto;
      color-scheme: light;
    }
    body {
      padding: 12px;
      box-sizing: border-box;
    }
    #diagram {
      width: 100%;
      min-height: 40px;
      background: #FFFFFF !important;
      background-color: #FFFFFF !important;
      overflow: visible;
      transform-origin: 0 0;
    }
    #diagram svg {
      display: block;
      max-width: 180%;
      height: auto;
      background: #FFFFFF !important;
      background-color: #FFFFFF !important;
      transform-origin: 0 0;
    }
    .render-error {
      white-space: pre-wrap;
      word-break: break-word;
      font: 12px ui-monospace, SFMono-Regular, Consolas, monospace;
      line-height: 18px;
      color: #B91C1C;
      background: #FEF2F2;
      border: 1px solid #FECACA;
      border-radius: 8px;
      padding: 10px;
    }
  </style>
</head>
<body>
  <div id="diagram"></div>
  <pre id="source" style="display:none">${sourceText}</pre>
  <script>
    const source = document.getElementById('source').textContent || '';
    const target = document.getElementById('diagram');
    const minScale = 0.6;
    const maxScale = 1.8;
    let diagramScale = 1;
    let resizeObserver = null;
    let lastReportedWidth = 0;
    let lastReportedHeight = 0;
    const mermaidUrls = [
      'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js',
      'https://unpkg.com/mermaid@11/dist/mermaid.min.js'
    ];
    function clampScale(value) {
      if (!Number.isFinite(value)) {
        return 1;
      }
      return Math.min(maxScale, Math.max(minScale, Math.round(value * 100) / 100));
    }
    function baseSvgWidth(svg) {
      const cachedWidth = parseFloat(svg.getAttribute('data-arkpilot-base-width') || '0');
      if (Number.isFinite(cachedWidth) && cachedWidth > 0) {
        return cachedWidth;
      }
      svg.style.width = '100%';
      svg.style.minWidth = '';
      svg.style.maxWidth = 'none';
      svg.style.height = 'auto';
      const rect = svg.getBoundingClientRect();
      let width = rect.width;
      if (!Number.isFinite(width) || width <= 0) {
        const attrWidth = parseFloat(svg.getAttribute('width') || '0');
        width = Number.isFinite(attrWidth) && attrWidth > 0 ? attrWidth : 0;
      }
      if (width <= 0) {
        width = Math.max(target.clientWidth, 320);
      }
      svg.setAttribute('data-arkpilot-base-width', width.toString());
      return width;
    }
    function safeNumber(value) {
      return Number.isFinite(value) && value > 0 ? value : 0;
    }
    function currentDiagramSize() {
      const svg = target.querySelector('svg');
      const html = document.documentElement;
      const body = document.body;
      const bodyRect = body.getBoundingClientRect();
      let measuredWidth = Math.max(
        safeNumber(html.scrollWidth),
        safeNumber(body.scrollWidth),
        safeNumber(target.scrollWidth),
        safeNumber(target.getBoundingClientRect().width)
      );
      let measuredHeight = Math.max(
        safeNumber(html.scrollHeight),
        safeNumber(body.scrollHeight),
        safeNumber(target.scrollHeight),
        safeNumber(target.getBoundingClientRect().height)
      );
      if (svg) {
        const svgRect = svg.getBoundingClientRect();
        measuredWidth = Math.max(measuredWidth, safeNumber(svgRect.right - bodyRect.left + 12));
        measuredHeight = Math.max(measuredHeight, safeNumber(svgRect.bottom - bodyRect.top + 12));
      }
      return {
        width: Math.ceil(measuredWidth),
        height: Math.ceil(measuredHeight)
      };
    }
    function reportDiagramSize() {
      const size = currentDiagramSize();
      if (size.height <= 0 || size.width <= 0) {
        return;
      }
      if (Math.abs(size.width - lastReportedWidth) < 2 && Math.abs(size.height - lastReportedHeight) < 2) {
        return;
      }
      lastReportedWidth = size.width;
      lastReportedHeight = size.height;
      if (window.arkpilotMermaidBridge && window.arkpilotMermaidBridge.reportSize) {
        window.arkpilotMermaidBridge.reportSize(size.width, size.height);
      }
    }
    function scheduleDiagramSizeReport() {
      requestAnimationFrame(function() {
        reportDiagramSize();
        setTimeout(reportDiagramSize, 80);
        setTimeout(reportDiagramSize, 240);
      });
    }
    function observeDiagramSize() {
      if (resizeObserver) {
        resizeObserver.disconnect();
        resizeObserver = null;
      }
      if (window.ResizeObserver) {
        resizeObserver = new ResizeObserver(scheduleDiagramSizeReport);
        resizeObserver.observe(target);
        const svg = target.querySelector('svg');
        if (svg) {
          resizeObserver.observe(svg);
        }
      }
      window.removeEventListener('resize', scheduleDiagramSizeReport);
      window.addEventListener('resize', scheduleDiagramSizeReport);
    }
    function applyDiagramScale() {
      diagramScale = clampScale(diagramScale);
      target.style.zoom = '';
      target.style.transform = 'none';
      target.style.width = '100%';
      const svg = target.querySelector('svg');
      if (svg) {
        const nextWidth = baseSvgWidth(svg) * diagramScale;
        const nextWidthText = nextWidth.toFixed(2) + 'px';
        svg.style.display = 'block';
        svg.style.transform = 'none';
        svg.style.transformOrigin = '0 0';
        svg.style.width = nextWidthText;
        svg.style.minWidth = nextWidthText;
        svg.style.maxWidth = '180%';
        svg.style.height = 'auto';
        svg.setAttribute('width', nextWidth.toFixed(2));
        scheduleDiagramSizeReport();
        return 'applied:' + nextWidthText;
      }
      scheduleDiagramSizeReport();
      return 'pending';
    }
    window.__arkpilotApplyMermaidScale = function(value) {
      diagramScale = clampScale(value);
      return applyDiagramScale();
    };
    function showError(error) {
      const detail = error && error.message ? error.message : String(error || 'Unknown Mermaid render error');
      target.innerHTML = '<div class="render-error">Mermaid 渲染失败\\n\\n' + detail.replace(/[&<>"']/g, function(ch) {
        return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch];
      }) + '</div>';
      scheduleDiagramSizeReport();
    }
    function loadMermaid(index) {
      if (window.mermaid) {
        return Promise.resolve();
      }
      if (index >= mermaidUrls.length) {
        return Promise.reject(new Error('Mermaid.js 未加载。请确认设备可以访问 jsdelivr 或 unpkg，或后续改为内置 mermaid.min.js。'));
      }
      return new Promise(function(resolve, reject) {
        const script = document.createElement('script');
        script.src = mermaidUrls[index];
        script.onload = function() { resolve(); };
        script.onerror = function() {
          loadMermaid(index + 1).then(resolve).catch(reject);
        };
        document.head.appendChild(script);
      });
    }
    async function renderDiagram() {
      try {
        await loadMermaid(0);
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: 'loose',
          theme: 'base',
          themeVariables: {
            primaryColor: '#DBEAFE',
            primaryTextColor: '#0F172A',
            primaryBorderColor: '#93C5FD',
            lineColor: '#2563EB',
            secondaryColor: '#F8FAFC',
            tertiaryColor: '#FFFFFF',
            background: '#FFFFFF',
            mainBkg: '#DBEAFE',
            secondBkg: '#F8FAFC',
            textColor: '#0F172A',
            fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
          }
        });
        const result = await mermaid.render('arkpilot-mermaid-' + Date.now().toString(), source);
        target.innerHTML = result.svg;
        if (result.bindFunctions) {
          result.bindFunctions(target);
        }
        applyDiagramScale();
        observeDiagramSize();
        scheduleDiagramSizeReport();
      } catch (error) {
        showError(error);
      }
    }
    if (document.readyState === 'loading') {
      window.addEventListener('DOMContentLoaded', renderDiagram);
    } else {
      renderDiagram();
    }
  </script>
</body>
</html>`;
  }

  private escapeHtml(text: string): string {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  private normalizedScale(value: number): number {
    if (value !== value) {
      return 1;
    }
    return Math.min(1.8, Math.max(0.6, value));
  }

  private normalizedDiagramHeight(value: number): number {
    if (value !== value || value <= 0) {
      return 260;
    }
    return Math.min(12000, Math.max(220, Math.ceil(value)));
  }

  private resetMeasuredDiagramHeight(): void {
    this.measuredDiagramHeight = this.normalizedDiagramHeight(this.diagramHeight);
  }

  private onSourceChanged(): void {
    this.resetMeasuredDiagramHeight();
  }

  private onDiagramHeightChanged(): void {
    this.resetMeasuredDiagramHeight();
  }

  private updateMeasuredDiagramSize(_width: number, height: number): void {
    const fallbackHeight: number = this.normalizedDiagramHeight(this.diagramHeight);
    const nextHeight: number = Math.max(fallbackHeight, this.normalizedDiagramHeight(height));
    if (Math.abs(nextHeight - this.measuredDiagramHeight) >= 2) {
      this.measuredDiagramHeight = nextHeight;
    }
  }

  private onFontScaleChanged(): void {
    const scaleText: string = this.normalizedScale(this.fontScale).toFixed(2);
    try {
      void this.controller.runJavaScript(
        `window.__arkpilotApplyMermaidScale && window.__arkpilotApplyMermaidScale(${scaleText});`
      );
    } catch (_err) {
    }
  }

  build() {
    Web({ src: this.mermaidDataUrl(), controller: this.controller })
      .javaScriptAccess(true)
      .javaScriptProxy({
        object: this.sizeBridge,
        name: 'arkpilotMermaidBridge',
        methodList: new Array<string>(),
        asyncMethodList: ['reportSize'],
        controller: this.controller
      })
      .darkMode(WebDarkMode.Off)
      .forceDarkAccess(false)
      .zoomAccess(false)
      .initialScale(100)
      .textZoomRatio(100)
      .onPageEnd(() => {
        this.onFontScaleChanged();
      })
      .width('100%')
      .height(this.measuredDiagramHeight)
      .backgroundColor('#FFFFFF')
      .zIndex(0)
      .hitTestBehavior(HitTestMode.Transparent)
  }
}
