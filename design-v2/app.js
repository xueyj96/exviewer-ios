(() => {
  'use strict';

  const params = new URLSearchParams(location.search);
  const requestedScreen = ['discover', 'search', 'detail', 'reader', 'library', 'account'].includes(params.get('screen')) ? params.get('screen') : 'discover';
  const previewMode = params.get('preview') === '1';

  const works = [
    { id: 'coast', cover: 'artwork/coast.svg', title: '潮线以北', meta: '画集 · 48 页 · 2025', category: '画集', artist: 'Mori', tags: ['coastline', 'sea', 'landscape'], ns: 'artist', pages: 48, rating: '4.8', progress: 63 },
    { id: 'rain', cover: 'artwork/rain.svg', title: '雨停之前的小店', meta: '插画集 · 32 页 · 2024', category: '画集', artist: 'Aki N.', tags: ['rain', 'shop', 'city'], ns: 'artist', pages: 32, rating: '4.6', progress: 28 },
    { id: 'garden', cover: 'artwork/garden.svg', title: '窗边的夏天', meta: '画集 · 64 页 · 2025', category: '画集', artist: 'Mori', tags: ['garden', 'plants', 'landscape'], ns: 'artist', pages: 64, rating: '4.9', progress: 41 },
    { id: 'night', cover: 'artwork/night.svg', title: '末班列车经过时', meta: '漫画 · 26 页 · 2023', category: '漫画', artist: 'Nagi', tags: ['train', 'night', 'city', 'spoiler'], ns: 'artist', pages: 26, rating: '4.5', progress: 12 },
    { id: 'letter', cover: 'artwork/letter.svg', title: '寄给春天的信', meta: '画集 · 40 页 · 2024', category: '画集', artist: 'Sora', tags: ['letter', 'flower', 'still life'], ns: 'artist', pages: 40, rating: '4.7', progress: 0 },
    { id: 'walk', cover: 'artwork/walk.svg', title: '山路慢慢走', meta: '画集 · 56 页 · 2025', category: '画集', artist: 'Kiyo', tags: ['mountain', 'walk', 'landscape'], ns: 'artist', pages: 56, rating: '4.8', progress: 75 }
  ];
  const notes = {
    discover: ['封面先行的发现页', '入口收紧到标题、站点和一条搜索栏；内容从首屏开始，以封面建立浏览节奏。'],
    search: ['条件直接落在结果里', '搜索、包含标签与负向标签在同一发现页面呈现；筛选从底部进入，修改后立即反映到条件与结果。'],
    detail: ['信息围绕作品展开', '封面、阅读入口、轻量操作和分组标签各就其位；标签动作通过菜单进入，避免把详情变成控制面板。'],
    reader: ['阅读优先的深色画布', '整页承载一张作品图；轻触切换阅读 chrome，底部控制页数、进度和阅读方式。'],
    library: ['收藏与本机资料分层', '站点收藏按分类浏览；继续阅读、手动下载、本机书签和搜索组合在同一滚动资料库中。'],
    account: ['账户设置更接近日常使用', '站点状态压缩展示，偏好、阅读、存储与权益用一致列表呈现；验证细节收进登录管理。']
  };
  const state = {
    screen: requestedScreen, theme: 'light', network: 'normal', loaded: false, retry: new Set(),
    site: 'EX', lane: 'latest', query: '', filtersOpen: params.get('filters') === '1', saveOpen: false, saveOriginId: null, tagOpen: false,
    titleOnly: false, tagMatch: '包含', tags: [], anyTags: [], excluded: [], category: '全部分类',
    rating: '不限', minPages: '', maxPages: '', savedSerial: 0, saved: [
      { id: 'preset-chinese', name: '中文画集', site: 'EH', query: '', titleOnly: false, tags: ['language:chinese'], anyTags: [], excluded: [], category: '画集', rating: '不限', minPages: '', maxPages: '', summary: 'EH · language:chinese · 画集' },
      { id: 'preset-landscape', name: '风景彩色', site: 'EX', query: '', titleOnly: false, tags: ['other:landscape'], anyTags: [], excluded: ['other:city'], category: '全部分类', rating: '不限', minPages: '', maxPages: '', summary: 'EX · other:landscape · 排除 other:city' },
      { id: 'preset-mori', name: '作者 Mori', site: 'EX', query: '', titleOnly: false, tags: ['artist:Mori'], anyTags: [], excluded: [], category: '全部分类', rating: '4 星以上', minPages: '', maxPages: '', summary: 'EX · artist:Mori · 4 星以上' }
    ], loadedSavedId: null, saveName: '', savedManagerOpen: false, bookmarks: new Set(['letter']), siteFavorites: new Set(['coast', 'rain']),
    localTab: params.get('local') === '1' ? 'local' : 'site', librarySection: 'all', selected: works[0], page: 17, readerChrome: true, thumbnailsOpen: false,
    downloading: true, downloaded: new Set(['garden']), blocked: new Set(['spoiler']), pinned: new Set(['artist:Mori', 'landscape']),
    toast: '', tagDraft: '', tagText: '', sponsorOpen: false, accountOpen: false, prefsOpen: false, settingsOpen: false, storageOpen: false,
    viewMode: 'single', orientation: 'vertical', darkReader: true, previousScreen: 'discover', loggedIn: true
  };
  if (state.screen === 'search') { state.query = '潮'; state.tags = ['artist:Mori']; state.excluded = ['other:spoiler']; state.titleOnly = true; }
  if (previewMode) document.body.classList.add('preview-mode');
  const app = document.getElementById('app');
  const phone = document.getElementById('phone');
  const picker = document.getElementById('screenPicker');
  const themeToggle = document.getElementById('themeToggle');
  const networkPicker = document.getElementById('networkPicker');
  const textSizeToggle = document.getElementById('textSizeToggle');
  let largeText = false;
  textSizeToggle.addEventListener('click', () => { largeText = !largeText; phone.style.setProperty('--ex-font-scale', largeText ? '1.22' : '1'); textSizeToggle.textContent = largeText ? 'A' : 'A+'; });
  const noteTitle = document.getElementById('noteTitle');
  const noteBody = document.getElementById('noteBody');

  const esc = (value) => String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const glyphs = {
    search: '<circle cx="10.8" cy="10.8" r="6.7"/><path d="m16 16 4.5 4.5"/>',
    filter: '<path d="M4 6h16M7 12h10m-7 6h4"/><circle cx="8" cy="6" r="1.6" fill="currentColor" stroke="none"/><circle cx="14" cy="12" r="1.6" fill="currentColor" stroke="none"/>',
    bookmark: '<path d="M6 4.5A1.5 1.5 0 0 1 7.5 3h9A1.5 1.5 0 0 1 18 4.5V21l-6-4-6 4Z"/>',
    library: '<path d="M5 4.5h13A1.5 1.5 0 0 1 19.5 6v14H6.5A2.5 2.5 0 0 1 4 17.5v-11A2.5 2.5 0 0 1 6.5 4H18M7 8h8M7 11h8M7 14h6"/>',
    account: '<circle cx="12" cy="8" r="3.5"/><path d="M4.5 20a7.5 7.5 0 0 1 15 0Z"/>',
    back: '<path d="m14.5 5-7 7 7 7"/>',
    download: '<path d="M12 3v12m-4-4 4 4 4-4M4 17v3h16v-3"/>',
    more: '<circle cx="5" cy="12" r="1" fill="currentColor"/><circle cx="12" cy="12" r="1" fill="currentColor"/><circle cx="19" cy="12" r="1" fill="currentColor"/>',
    next: '<path d="m9 5 7 7-7 7"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>',
    star: '<path d="m12 3 2.7 5.5 6.1.9-4.4 4.3 1 6.1-5.4-2.9-5.4 2.9 1-6.1-4.4-4.3 6.1-.9Z"/>',
    pages: '<rect x="4" y="4" width="6" height="7" rx="1"/><rect x="14" y="4" width="6" height="7" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><rect x="14" y="14" width="6" height="6" rx="1"/>',
    preferences: '<path d="M4 6h16M4 12h16M4 18h16"/><circle cx="9" cy="6" r="2" fill="var(--paper)"/><circle cx="15" cy="12" r="2" fill="var(--paper)"/><circle cx="8" cy="18" r="2" fill="var(--paper)"/>',
    storage: '<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M8 8h8M8 12h8M8 16h4"/>',
    benefit: '<path d="M12 3.5 14 8l4.5-2-2 4.5 4.5 2-4.5 2 2 4.5-4.5-2-2 4.5-2-4.5-4.5 2 2-4.5L3 12.5l4.5-2-2-4.5L10 8Z"/>'
  };
  const icon = (name, size = 18, filled = false) => `<svg class="icon-svg" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${glyphs[name] || glyphs.more}</svg>`;
  const selected = () => state.selected || works[0];
  const rootView = () => ['discover', 'search'].includes(state.screen) ? 'discover' : state.screen;
  const nav = (active) => `<nav class="bottom-nav" aria-label="主导航">
    <button class="nav-item ${active === 'discover' ? 'active' : ''}" data-nav="discover" aria-label="发现">${icon('search')}<span>发现</span></button>
    <button class="nav-item ${active === 'library' ? 'active' : ''}" data-nav="library" aria-label="资料库">${icon('library')}<span>资料库</span></button>
    <button class="nav-item ${active === 'account' ? 'active' : ''}" data-nav="account" aria-label="账号">${icon('account')}<span>账号</span></button>
  </nav>`;
  const head = (title, right = '') => `<header class="page-head"><h2>${title}</h2><div class="head-right">${right}</div></header>`;
  const siteButton = () => `<button class="site-switch" data-action="site" aria-label="切换站点">${state.site}</button>`;
  const art = (work, extra = '') => `<img src="${work.cover}" alt="${esc(work.title)}封面" ${extra}>`;
  const visibleWorks = () => {
    let pool = state.lane === 'hot' ? [...works].sort((a, b) => Number(b.rating) - Number(a.rating)) : works;
    const needle = state.query.trim().toLowerCase();
    if (needle) pool = pool.filter((w) => (state.titleOnly ? w.title : `${w.title} ${w.artist} ${w.tags.join(' ')}`).toLowerCase().includes(needle));
    const matchesTag = (work, tag) => {
      const [namespace, ...rest] = tag.toLowerCase().split(':');
      const value = rest.join(':') || namespace;
      if (namespace === 'artist') return work.artist.toLowerCase() === value;
      if (namespace === 'language') return value === 'chinese';
      return work.tags.includes(value);
    };
    if (state.tags.length) pool = pool.filter((w) => state.tags.every((tag) => matchesTag(w, tag)));
    if (state.anyTags.length) pool = pool.filter((w) => state.anyTags.some((tag) => matchesTag(w, tag)));
    if (state.excluded.length) pool = pool.filter((w) => !state.excluded.some((tag) => matchesTag(w, tag)));
    if (state.category !== '全部分类') pool = pool.filter((w) => w.category === state.category);
    if (state.rating === '4 星以上') pool = pool.filter((w) => Number(w.rating) >= 4);
    if (state.rating === '5 星') pool = pool.filter((w) => Number(w.rating) >= 4.9);
    if (state.minPages) pool = pool.filter((w) => w.pages >= Number(state.minPages));
    if (state.maxPages) pool = pool.filter((w) => w.pages <= Number(state.maxPages));
    if (state.blocked.size) pool = pool.filter((w) => ![...state.blocked].some((tag) => matchesTag(w, tag)));
    return pool;
  };
  function coverCard(work, index) {
    const failed = state.network === 'failure' && index === 1 && !state.retry.has(work.id);
    const loading = state.network === 'loading' || (!state.loaded && state.network === 'normal');
    return `<article class="work" data-open="${work.id}" tabindex="0" role="button" aria-label="打开${esc(work.title)}">
      <div class="cover">${loading ? '<div class="skeleton"></div>' : art(work)}${failed ? `<button class="cover-retry" data-retry="${work.id}"><span>轻点重试</span></button>` : ''}</div>
      <div class="work-title">${esc(work.title)}</div><p class="work-meta">${esc(work.meta)}</p></article>`;
  }
  function hasActiveConditions() { return Boolean(state.query || state.tags.length || state.anyTags.length || state.excluded.length || state.titleOnly || state.category !== '全部分类' || state.rating !== '不限' || state.minPages || state.maxPages); }
  function savedSummary(saved) {
    return [saved.site || 'EX', saved.query, saved.titleOnly ? '仅标题' : '', ...(saved.tags || []).map((tag) => `包含 ${tag}`), ...(saved.anyTags || []).map((tag) => `任一 ${tag}`), ...(saved.excluded || []).map((tag) => `排除 ${tag}`), saved.category !== '全部分类' ? saved.category : '', saved.rating !== '不限' ? saved.rating : '', saved.minPages || saved.maxPages ? `${saved.minPages || 0}–${saved.maxPages || '不限'} 页` : ''].filter(Boolean).join(' · ');
  }
  function loadSaved(index) {
    const saved = state.saved[index];
    if (!saved) return;
    state.site = saved.site || 'EX'; state.query = saved.query || ''; state.titleOnly = Boolean(saved.titleOnly);
    state.tags = [...(saved.tags || [])]; state.anyTags = [...(saved.anyTags || [])]; state.excluded = [...(saved.excluded || [])];
    state.category = saved.category || '全部分类'; state.rating = saved.rating || '不限';
    state.minPages = saved.minPages || ''; state.maxPages = saved.maxPages || '';
    state.loadedSavedId = saved.id; state.screen = 'discover'; state.lane = 'latest';
  }
  function captureSaved(name, id) {
    const saved = { id, name, site: state.site, query: state.query, titleOnly: state.titleOnly, tags: [...state.tags], anyTags: [...state.anyTags], excluded: [...state.excluded], category: state.category, rating: state.rating, minPages: state.minPages, maxPages: state.maxPages };
    saved.summary = savedSummary(saved);
    return saved;
  }
  function chipRow() {
    const chips = [];
    if (state.titleOnly) chips.push('<span class="chip">标题范围</span>');
    state.tags.forEach((tag) => chips.push(`<button class="chip" data-chip="${esc(tag)}">包含 · ${esc(tag)} ${icon('close', 11)}</button>`));
    state.excluded.forEach((tag) => chips.push(`<button class="chip negative" data-exclude="${esc(tag)}">排除 · ${esc(tag)} ${icon('close', 11)}</button>`));
    if (state.category !== '全部分类') chips.push(`<span class="chip">${esc(state.category)}</span>`);
    state.anyTags.forEach((tag) => chips.push(`<button class="chip" data-any-tag="${esc(tag)}">任一 · ${esc(tag)} ${icon('close', 11)}</button>`));
    if (state.rating !== '不限') chips.push(`<span class="chip">${esc(state.rating)}</span>`);
    if (state.minPages || state.maxPages) chips.push(`<span class="chip">${state.minPages || 0}–${state.maxPages || '不限'} 页</span>`);
    if (state.query) chips.unshift(`<span class="chip">${esc(state.query)}</span>`);
    if (!chips.length) return '';
    return `<div class="result-context">${chips.join('')}<button class="chip clear" data-action="clear-search">清除</button></div>`;
  }
  function discovery() {
    const results = visibleWorks();
    const filters = hasActiveConditions();
    const actions = `<button class="icon-button" data-action="open-filters" aria-label="筛选">${icon('filter')}</button>`;
    const tools = filters ? `<div class="result-tools"><span>${results.length} 个结果</span><button data-action="save-open" aria-label="保存搜索组合">${icon('bookmark')}</button></div>` : '';
    return `<section class="page with-nav">
      ${head('发现', siteButton())}
      <form class="search-field" id="searchForm"><span class="search-icon">${icon('search')}</span><input id="queryInput" type="search" autocomplete="off" placeholder="搜索标题、作者或标签" value="${esc(state.query)}" aria-label="搜索标题、作者或标签">${state.query ? `<button type="button" data-action="clear-text" aria-label="清除文本">${icon('close')}</button>` : ''}${actions}</form>
      <div class="saved-shortcuts" aria-label="常用搜索组合"><span>${state.loadedSavedId ? `已载入：${esc(state.saved.find((item) => item.id === state.loadedSavedId)?.name || '组合')}` : '常用组合'}</span><div class="shortcut-scroll">${state.saved.map((item, index) => `<button class="${state.loadedSavedId === item.id ? 'selected' : ''}" data-apply-saved="${index}" aria-label="载入并执行组合：${esc(item.name)}">${esc(item.name)}</button>`).join('')}</div><button class="shortcut-manage" data-action="saved-manager" aria-label="查看全部组合">全部</button><button class="shortcut-manage" data-action="saved-manager" aria-label="管理搜索组合">管理</button></div>
      <div class="tabs"><button class="tab ${state.lane === 'latest' ? 'selected' : ''}" data-lane="latest">最新</button><button class="tab ${state.lane === 'hot' ? 'selected' : ''}" data-lane="hot">热门</button></div>
      ${chipRow()}${tools}
      ${state.network === 'failure' && results[1] && !state.retry.has(results[1].id) ? '<div class="inline-message">部分封面暂时没有加载，已显示内容仍可继续浏览。</div>' : ''}
      <div class="gallery-grid">${results.map(coverCard).join('') || '<div class="empty-state">没有符合当前条件的作品。<br>调整标签或清除条件继续浏览。</div>'}</div>
      ${nav('discover')}
    </section>`;
  }
  function detail() {
    const work = selected();
    const groups = [
      ['artist', [work.artist]], ['other', work.tags], ['language', ['chinese']]
    ];
    const preview = [1, 2, 3, 4];
    return `<section class="page detail-page">
      <header class="page-head"><button class="back-button" data-action="back" aria-label="返回">${icon('back')}</button><span class="work-count">作品详情</span><span style="width:40px"></span></header>
      <div class="detail-top">${art(work, 'class="detail-cover"')}<div class="detail-copy"><h3>${esc(work.title)}</h3><p>${esc(work.artist)} · 2025</p><p>${esc(work.meta)}</p><p class="rating">${icon('star', 13)} ${work.rating}　${state.site}</p></div></div>
      <div class="detail-actions"><button class="primary" data-action="read">${work.progress > 0 ? '继续阅读' : '开始阅读'}</button><button class="secondary-action ${state.bookmarks.has(work.id) ? 'active' : ''}" data-action="bookmark" aria-label="本机书签">${icon('bookmark')}</button><button class="secondary-action" data-action="download" aria-label="下载到本机">${icon('download')}</button></div>
      <h4 class="detail-label">作品预览</h4><div class="preview-row">${preview.map((page) => `<button class="preview-page" data-preview-page="${page}" aria-label="阅读第 ${page} 页">${art(work)}<span>${page}</span></button>`).join('')}</div>
      <h4 class="detail-label">标签</h4><div class="tag-groups">${groups.map(([name, tags]) => `<div class="tag-group"><strong>${name}</strong><div class="tag-list">${tags.map((tag) => `<button class="tag-pill" data-tag="${esc(name + ':' + tag)}">${esc(tag)}</button>`).join('')}</div></div>`).join('')}</div>
    </section>`;
  }
  function reader() {
    const work = selected();
    const pct = Math.min(100, Math.round(state.page / work.pages * 100));
    return `<section class="reader ${state.readerChrome ? '' : 'hidden-chrome'} ${state.darkReader ? '' : 'light-reader'}">
      <header class="reader-top"><button data-action="back" aria-label="返回详情">${icon('back')}</button><span>${esc(work.title)}</span><button data-action="reader-settings" aria-label="阅读设置">${icon('more')}</button></header>
      <div class="reader-image-wrap" data-action="toggle-chrome">${art(work, 'class="reader-image"')}<span class="animated-sun" aria-hidden="true" style="position:absolute;right:16%;top:22%;width:18px;height:18px;border-radius:50%;background:#0a84ff40;filter:blur(2px);pointer-events:none"></span></div>
      <footer class="reader-bottom"><div class="reader-controls"><button data-action="prev-page" aria-label="上一页">${icon('back')}</button><span class="reader-page">${state.page} / ${work.pages}</span><button data-action="next-page" aria-label="下一页">${icon('next')}</button></div>${state.thumbnailsOpen ? `<div class="reader-thumbnails">${[1, 9, 17, 25, 33, 41].filter((p) => p <= work.pages).map((p) => `<button data-page-jump="${p}" class="${p === state.page ? 'selected' : ''}">${art(work)}<span>${p}</span></button>`).join('')}</div>` : ''}<div class="reader-progress"><i style="width:${pct}%"></i></div><div class="reader-subcontrols"><button data-action="thumbnails">${icon('pages')} 缩略图</button><button data-action="reader-settings">${state.viewMode === 'single' ? '单页' : '连续'} · ${state.orientation === 'vertical' ? '纵向' : '横向'}</button></div></footer>
    </section>`;
  }
  function library() {
    const siteMode = state.localTab === 'site';
    const controls = `<div class="library-tabs"><button class="${siteMode ? 'selected' : ''}" data-library-tab="site">站点收藏</button><button class="${!siteMode ? 'selected' : ''}" data-library-tab="local">本机资料</button></div>`;
    if (siteMode) {
      const items = works.filter((w) => state.siteFavorites.has(w.id) && (state.category === '全部分类' || w.category === state.category));
      return `<section class="page with-nav">${head('资料库', siteButton())}${controls}<select class="category-select" id="categorySelect" aria-label="收藏分类"><option ${state.category === '全部分类' ? 'selected' : ''}>全部分类</option><option ${state.category === '画集' ? 'selected' : ''}>画集</option><option ${state.category === '漫画' ? 'selected' : ''}>漫画</option></select><div class="gallery-grid">${items.map(coverCard).join('') || '<div class="empty-state">这里还没有站点收藏。</div>'}</div>${nav('library')}</section>`;
    }
    const resumes = works.filter((w) => w.progress > 0).slice(0, 2);
    const completed = [...state.downloaded].map((id) => works.find((w) => w.id === id)).filter(Boolean);
    const saved = state.saved;
    return `<section class="page with-nav">${head('资料库', siteButton())}${controls}
        <div class="section-title">继续阅读 <small>2 本</small></div><div class="resume-strip">${resumes.map((w) => `<div class="resume-item" data-open="${w.id}">${art(w)}<div class="resume-info"><b>${esc(w.title)}</b><small>第 ${Math.round(w.progress / 100 * w.pages)} 页 · ${w.progress}%</small><div class="progress"><i style="width:${w.progress}%"></i></div></div></div>`).join('')}</div>
      <div class="section-title">手动下载 <small>长期保留</small></div><div class="download-row">${art(works[2])}<div class="download-info"><b>窗边的夏天</b><small>${state.downloading ? '下载中 · 18 / 64 页' : '已暂停 · 18 / 64 页'}</small><div class="progress"><i style="width:28%"></i></div></div><button class="text-link" data-action="pause">${state.downloading ? '暂停' : '继续'}</button></div>${completed.filter((w) => w.id !== 'garden').map((w) => `<div class="download-row" data-open="${w.id}">${art(w)}<div class="download-info"><b>${esc(w.title)}</b><small>已完成 · 点按阅读</small></div><button class="text-link" data-read="${w.id}">阅读</button></div>`).join('')}
      <div class="section-title">本机书签 <small>${state.bookmarks.size} 项</small></div><div class="mini-grid">${[...state.bookmarks].map((id) => works.find((w) => w.id === id)).filter(Boolean).map((w) => `<div class="mini-work" data-open="${w.id}">${art(w)}<span>${esc(w.title)}</span></div>`).join('') || '<p class="work-meta">详情页可加入本机书签。</p>'}</div>
      <div class="section-title">常用搜索组合</div>${saved.map((s, i) => `<div class="saved-search"><span class="saved-icon">${icon('search')}</span><div><b>${esc(s.name)}</b><small>${esc(s.summary)}</small></div><button class="text-link" data-apply-saved="${i}">执行</button></div>`).join('') || '<div class="saved-search"><span class="work-meta">保存后的组合会显示在这里。</span></div>'}
      ${nav('library')}</section>`;
  }
  function account() {
    return `<section class="page with-nav">${head('账号')}
      <div class="profile"><div class="avatar">${icon('account', 21)}</div><div class="profile-copy"><b>站点账号</b><small>${state.loggedIn === false ? '已退出' : '已登录'}</small></div><button class="text-link" data-action="account-manage">管理</button></div>
      <div class="account-stats"><span class="status-pill"><i></i> EH 可访问</span><span class="status-pill"><i></i> EX 可访问</span></div>
      <div class="quota"><div class="quota-top"><span>看图额度</span><span>3,800 / 10,000</span></div><div class="quota-track"><i></i></div></div>
      <div class="list-section-label">偏好</div>
      <button class="account-row" data-action="preferences">${icon('preferences')}<span class="row-main"><b>标签偏好</b><small>常用标签与屏蔽标签</small></span>${icon('next')}</button>
      <button class="account-row" data-action="reading-settings">${icon('pages')}<span class="row-main"><b>阅读设置</b><small>页面方向、背景与翻页方式</small></span>${icon('next')}</button>
      <div class="list-section-label">本机</div>
      <button class="account-row" data-action="storage">${icon('storage')}<span class="row-main"><b>存储管理</b><small>浏览缓存 2 GB · 手动下载长期保留</small></span>${icon('next')}</button>
      <div class="list-section-label">站点权益</div>
      <button class="account-row" data-action="sponsor">${icon('benefit')}<span class="row-main"><b>站点赞助与权益</b><small>了解站点账户与支持方式</small></span>${icon('next')}</button>
      ${nav('account')}</section>`;
  }
  function sheet() {
    if (state.savedManagerOpen) return `<div class="sheet-backdrop" data-dismiss="saved-manager"><section class="sheet saved-manager-sheet" role="dialog" aria-modal="true" aria-label="全部搜索组合"><div class="sheet-handle"></div><div class="sheet-title"><h3>常用搜索组合</h3><button data-action="close-saved-manager" aria-label="关闭">${icon('close')}</button></div><div class="saved-manager-list">${state.saved.map((item, index) => `<article class="saved-manager-item"><div class="saved-manager-copy"><strong>${esc(item.name)}</strong><p>${esc(savedSummary(item))}</p></div><div class="saved-manager-actions"><button data-apply-saved="${index}" aria-label="执行组合：${esc(item.name)}">执行</button><button data-edit-saved="${index}" aria-label="编辑组合：${esc(item.name)}">编辑</button></div></article>`).join('') || '<p class="work-meta">暂无已保存组合。</p>'}</div></section></div>`;
    if (state.filtersOpen) return `<div class="sheet-backdrop" data-dismiss="filters"><section class="sheet" role="dialog" aria-modal="true" aria-label="筛选条件"><div class="sheet-handle"></div><div class="sheet-title"><h3>搜索筛选</h3><button data-action="close-filters" aria-label="关闭">${icon('close')}</button></div>
      <div class="filter-section"><strong>标题范围</strong><div class="segmented"><button class="${state.titleOnly ? 'selected' : ''}" data-title-only="true">只匹配标题</button><button class="${!state.titleOnly ? 'selected' : ''}" data-title-only="false">标题与标签</button></div></div>
      <div class="filter-section"><strong>标签匹配方式</strong><div class="segmented">${['包含', '任一', '排除'].map((m) => `<button class="${state.tagMatch === m ? 'selected' : ''}" data-tag-match="${m}">${m}</button>`).join('')}</div></div>
      <div class="filter-section"><strong>添加标签</strong><form id="tagForm" class="sheet-row"><input class="sheet-input" id="tagInput" aria-label="标签原名" placeholder="namespace:标签原名" value="${esc(state.tagText)}" autocomplete="off"><button type="submit" class="text-link">添加</button></form></div><div class="filter-section"><strong>常用标签 · 点选加入</strong><div class="tag-selects">${['artist:Mori', 'other:landscape', 'other:flower', 'other:city', 'language:chinese', 'other:spoiler'].map((t) => `<button class="${state.tags.includes(t) || state.anyTags.includes(t) || state.excluded.includes(t) ? 'selected' : ''}" data-pick-tag="${t}">${t}</button>`).join('')}</div></div>
      <div class="filter-section"><strong>分类 / 评分 / 页数</strong><div class="sheet-row"><select class="sheet-input" id="filterCategory"><option ${state.category === '全部分类' ? 'selected' : ''}>全部分类</option><option ${state.category === '画集' ? 'selected' : ''}>画集</option><option ${state.category === '漫画' ? 'selected' : ''}>漫画</option></select><select class="sheet-input" id="filterRating"><option ${state.rating === '不限' ? 'selected' : ''}>不限</option><option ${state.rating === '4 星以上' ? 'selected' : ''}>4 星以上</option><option ${state.rating === '5 星' ? 'selected' : ''}>5 星</option></select></div><div class="sheet-row" style="margin-top:7px"><input class="sheet-input" id="minPages" inputmode="numeric" placeholder="最少页数" value="${esc(state.minPages)}"><input class="sheet-input" id="maxPages" inputmode="numeric" placeholder="最多页数" value="${esc(state.maxPages)}"></div></div>
      <button class="sheet-primary" data-action="apply-filters">应用筛选</button></section></div>`;
    if (state.saveOpen) {
      const original = state.saved.find((item) => item.id === state.saveOriginId);
      return `<div class="sheet-backdrop" data-dismiss="save"><section class="sheet" role="dialog" aria-modal="true" aria-label="保存搜索组合"><div class="sheet-handle"></div><div class="sheet-title"><h3>${original ? '更新或另存组合' : '保存搜索组合'}</h3><button data-action="close-save" aria-label="关闭">${icon('close')}</button></div><label class="modal-field">组合名称<input id="saveName" aria-label="组合名称" value="${esc(state.saveName)}" placeholder="给这组条件命名"></label><p class="work-meta">${esc(savedSummary(captureSaved('', 'draft')))}</p>${original ? `<button class="modal-action-button" data-action="save-update" aria-label="更新原组合：${esc(original.name)}">更新「${esc(original.name)}」</button>` : ''}<button class="sheet-primary" data-action="save-as-new" aria-label="另存为新组合">${original ? '另存为新组合' : '保存组合'}</button></section></div>`;
    }
    if (state.tagOpen) return `<div class="sheet-backdrop" data-dismiss="tag"><section class="sheet" role="dialog" aria-modal="true"><div class="sheet-handle"></div><div class="sheet-title"><h3>${esc(state.tagDraft)}</h3><button data-action="close-tag" aria-label="关闭">${icon('close')}</button></div><div class="detail-sheet-actions"><button data-action="tag-search">加入当前搜索</button><button data-action="tag-pin">加入常用标签</button><button data-action="tag-block">屏蔽此标签</button></div></section></div>`;
    if (state.accountOpen) return `<div class="sheet-backdrop" data-dismiss="account"><section class="sheet" role="dialog" aria-modal="true"><div class="sheet-handle"></div><div class="sheet-title"><h3>登录管理</h3><button data-action="close-account" aria-label="关闭">${icon('close')}</button></div>${['E-Hentai', 'ExHentai'].map((n) => `<div class="manage-status"><span>${n}<br><small>可访问</small></span><button data-action="verify">验证</button></div>`).join('')}<div class="modal-actions"><button data-action="web-login">网页登录</button><button data-action="logout">退出</button></div></section></div>`;
    if (state.prefsOpen) return `<div class="sheet-backdrop" data-dismiss="prefs"><section class="sheet" role="dialog" aria-modal="true"><div class="sheet-handle"></div><div class="sheet-title"><h3>标签偏好</h3><button data-action="close-prefs" aria-label="关闭">${icon('close')}</button></div><strong class="work-meta">常用标签</strong><div class="pref-tags">${[...state.pinned].map((t) => `<button data-unpin="${esc(t)}">${esc(t)}　移除</button>`).join('') || '<span class="work-meta">暂无</span>'}</div><strong class="work-meta" style="display:block;margin-top:15px">屏蔽标签</strong><div class="pref-tags">${[...state.blocked].map((t) => `<button data-unblock="${esc(t)}">${esc(t)}　撤销</button>`).join('') || '<span class="work-meta">暂无</span>'}</div><button class="sheet-primary" data-action="close-prefs">完成</button></section></div>`;
    if (state.settingsOpen) return `<div class="sheet-backdrop" data-dismiss="settings"><section class="sheet" role="dialog" aria-modal="true"><div class="sheet-handle"></div><div class="sheet-title"><h3>阅读设置</h3><button data-action="close-settings" aria-label="关闭">${icon('close')}</button></div><div class="filter-section"><strong>阅读方式</strong><div class="segmented"><button class="${state.viewMode === 'single' ? 'selected' : ''}" data-view-mode="single">单页</button><button class="${state.viewMode === 'continuous' ? 'selected' : ''}" data-view-mode="continuous">连续</button></div></div><div class="filter-section"><strong>翻页方向</strong><div class="segmented"><button class="${state.orientation === 'vertical' ? 'selected' : ''}" data-orientation="vertical">纵向</button><button class="${state.orientation === 'horizontal' ? 'selected' : ''}" data-orientation="horizontal">横向</button></div></div><div class="toggle-row">深色阅读背景<button class="toggle ${state.darkReader ? 'on' : ''}" data-action="reader-theme"></button></div></section></div>`;
    if (state.storageOpen) return `<div class="sheet-backdrop" data-dismiss="storage"><section class="sheet" role="dialog" aria-modal="true"><div class="sheet-handle"></div><div class="sheet-title"><h3>存储管理</h3><button data-action="close-storage" aria-label="关闭">${icon('close')}</button></div><div class="manage-status"><span>浏览缓存<small>上限 2 GB · 可自动整理</small></span><b>1.2 GB</b></div><div class="manage-status"><span>手动下载<small>长期保留 · 不自动清理</small></span><b>3.4 GB</b></div></section></div>`;
    if (state.sponsorOpen) return `<div class="sheet-backdrop" data-dismiss="sponsor"><section class="sheet" role="dialog" aria-modal="true"><div class="sheet-handle"></div><div class="sheet-title"><h3>站点赞助与权益</h3><button data-action="close-sponsor" aria-label="关闭">${icon('close')}</button></div><p style="font-size:13px;line-height:1.6">站点赞助可提高看图额度并获得归档相关权益。具体额度与费用以官方页面和当前账号为准。</p><button class="sheet-primary" data-action="close-sponsor">知道了</button></section></div>`;
    if (state.toast) return `<div class="toast-backdrop"><div class="toast"><p>${esc(state.toast)}</p><button class="sheet-primary" data-action="toast-close">好</button></div></div>`;
    return '';
  }
  function render() {
    phone.dataset.theme = state.theme;
    picker.value = state.screen;
    const notesForPage = notes[state.screen] || notes.discover;
    noteTitle.textContent = notesForPage[0]; noteBody.textContent = notesForPage[1];
    let content;
    if (state.screen === 'discover' || state.screen === 'search') content = discovery();
    else if (state.screen === 'detail') content = detail();
    else if (state.screen === 'reader') content = reader();
    else if (state.screen === 'library') content = library();
    else content = account();
    app.innerHTML = content + sheet();
  }
  function updateSearchInput(value) {
    state.query = value;
    const current = app.querySelector('.result-context');
    const next = document.createElement('div'); next.innerHTML = chipRow();
    if (current && next.firstElementChild) current.replaceWith(next.firstElementChild);
    else if (current) current.remove();
    else if (next.firstElementChild) app.querySelector('.tabs').after(next.firstElementChild);
    const tools = app.querySelector('.result-tools span');
    if (tools) tools.textContent = `${visibleWorks().length} 个结果`;
    const activeConditions = hasActiveConditions();
    let resultTools = app.querySelector('.result-tools');
    if (activeConditions && !resultTools) {
      app.querySelector('.gallery-grid')?.insertAdjacentHTML('beforebegin', `<div class="result-tools"><span>${visibleWorks().length} 个结果</span><button data-action="save-open" aria-label="保存搜索组合">${icon('bookmark')}</button></div>`);
      resultTools = app.querySelector('.result-tools');
    } else if (!activeConditions && resultTools) resultTools.remove();
    const grid = app.querySelector('.gallery-grid');
    if (grid) grid.innerHTML = visibleWorks().map(coverCard).join('') || '<div class="empty-state">没有符合当前条件的作品。<br>调整标签或清除条件继续浏览。</div>';
    const form = app.querySelector('#searchForm');
    if (form && value && !form.querySelector('[data-action="clear-text"]')) form.insertAdjacentHTML('beforeend', `<button type="button" data-action="clear-text" aria-label="清除文本">${icon('close')}</button>`);
    if (form && !value) form.querySelector('[data-action="clear-text"]')?.remove();
  }
  function chooseTag(value) {
    const tag = value.trim(); if (!tag) return;
    const key = state.tagMatch === '排除' ? 'excluded' : state.tagMatch === '任一' ? 'anyTags' : 'tags';
    const already = state[key].some((t) => t.toLowerCase() === tag.toLowerCase());
    ['tags', 'anyTags', 'excluded'].forEach((group) => { state[group] = state[group].filter((t) => t.toLowerCase() !== tag.toLowerCase()); });
    if (!already) state[key].push(tag);
  }
  function toast(message) { state.toast = message; render(); }
  function setScreen(screen) { state.screen = screen; render(); }
  function openWork(id) { state.selected = works.find((w) => w.id === id) || works[0]; state.previousScreen = state.screen === 'search' ? 'discover' : state.screen; state.screen = 'detail'; render(); }
  function beginRead() { state.page = Math.max(1, Math.round(selected().progress / 100 * selected().pages)); state.screen = 'reader'; state.readerChrome = true; render(); }

  picker.addEventListener('change', () => {
    state.screen = picker.value;
    if (state.screen === 'search') { state.query = '潮'; state.tags = ['artist:Mori']; state.excluded = ['other:spoiler']; state.titleOnly = true; state.tagMatch = '包含'; }
    render();
  });
  themeToggle.addEventListener('click', () => {
    state.theme = state.theme === 'light' ? 'dark' : 'light';
    themeToggle.innerHTML = `<svg viewBox="0 0 20 20" width="16" height="16" aria-hidden="true"><circle cx="10" cy="10" r="7" fill="none" stroke="currentColor"/><path d="M10 3a7 7 0 0 1 0 14Z" fill="currentColor"/></svg><span>${state.theme === 'light' ? '浅色' : '深色'}</span>`;
    render();
  });
  networkPicker.addEventListener('change', () => {
    state.network = networkPicker.value; state.retry.clear();
    state.loaded = state.network !== 'loading';
    render();
    if (state.network === 'normal') window.setTimeout(() => { state.loaded = true; render(); }, 650);
  });
  app.addEventListener('input', (event) => {
    if (event.target.id === 'queryInput') updateSearchInput(event.target.value);
    if (event.target.id === 'saveName') state.saveName = event.target.value;
    if (event.target.id === 'minPages') state.minPages = event.target.value;
    if (event.target.id === 'maxPages') state.maxPages = event.target.value;
    if (event.target.id === 'tagInput') state.tagText = event.target.value;
  });
  app.addEventListener('submit', (event) => { if (event.target.id === 'tagForm') { event.preventDefault(); chooseTag(app.querySelector('#tagInput').value); state.tagText = ''; render(); return; } if (event.target.id === 'searchForm') { event.preventDefault(); state.query = app.querySelector('#queryInput').value.trim(); render(); } });
  app.addEventListener('change', (event) => {
    if (event.target.id === 'categorySelect') { state.category = event.target.value; render(); }
    if (event.target.id === 'filterRating') state.rating = event.target.value;
    if (event.target.id === 'filterCategory') state.category = event.target.value;
  });
  app.addEventListener('click', (event) => {
    const backdrop = event.target.closest('[data-dismiss]');
    if (backdrop && event.target === backdrop) {
      const key = backdrop.dataset.dismiss;
      const stateKey = key === 'save' ? 'saveOpen' : key === 'saved-manager' ? 'savedManagerOpen' : `${key}Open`;
      state[stateKey] = false; render(); return;
    }
    const target = event.target.closest('button,[data-nav],[data-open],[data-read],[data-apply-saved],[data-lane],[data-library-tab],[data-tag],[data-retry],[data-title-only],[data-tag-match],[data-pick-tag],[data-view-mode],[data-orientation],[data-unpin],[data-unblock],[data-page-jump],[data-preview-page]');
    if (!target) {
      if (event.target.classList.contains('reader-image') || event.target.classList.contains('animated-sun')) { state.readerChrome = !state.readerChrome; render(); }
      return;
    }
    if (target.dataset.previewPage) { state.page = Number(target.dataset.previewPage); state.screen = 'reader'; state.readerChrome = true; render(); return; }
    if (target.dataset.pageJump) { state.page = Number(target.dataset.pageJump); render(); return; }
    if (target.dataset.retry) { state.retry.add(target.dataset.retry); render(); return; }
    if (target.dataset.chip) { state.tags = state.tags.filter((tag) => tag !== target.dataset.chip); render(); return; }
    if (target.dataset.anyTag) { state.anyTags = state.anyTags.filter((tag) => tag !== target.dataset.anyTag); render(); return; }
    if (target.dataset.exclude) { state.excluded = state.excluded.filter((tag) => tag !== target.dataset.exclude); render(); return; }
    if (target.dataset.nav) { state.screen = target.dataset.nav; render(); return; }
    if (target.dataset.open) { openWork(target.dataset.open); return; }
    if (target.dataset.read) { state.selected = works.find((w) => w.id === target.dataset.read) || selected(); beginRead(); return; }
    if (target.dataset.applySaved !== undefined) { state.savedManagerOpen = false; loadSaved(Number(target.dataset.applySaved)); render(); return; }
    if (target.dataset.editSaved !== undefined) { state.savedManagerOpen = false; loadSaved(Number(target.dataset.editSaved)); state.filtersOpen = true; render(); return; }
    if (target.dataset.lane) { state.lane = target.dataset.lane; render(); return; }
    if (target.dataset.libraryTab) { state.localTab = target.dataset.libraryTab; render(); return; }
    if (target.dataset.tag) { state.tagDraft = target.dataset.tag; state.tagOpen = true; render(); return; }
    if (target.dataset.titleOnly !== undefined) { state.titleOnly = target.dataset.titleOnly === 'true'; render(); return; }
    if (target.dataset.tagMatch) { state.tagMatch = target.dataset.tagMatch; render(); return; }
    if (target.dataset.pickTag) {
      chooseTag(target.dataset.pickTag);
      render(); return;
    }
    if (target.dataset.viewMode) { state.viewMode = target.dataset.viewMode; render(); return; }
    if (target.dataset.orientation) { state.orientation = target.dataset.orientation; render(); return; }
    if (target.dataset.unpin) { state.pinned.delete(target.dataset.unpin); render(); return; }
    if (target.dataset.unblock) { state.blocked.delete(target.dataset.unblock); render(); return; }
    const action = target.dataset.action;
    if (action === 'site') { state.site = state.site === 'EX' ? 'EH' : 'EX'; render(); }
    else if (action === 'open-filters') { state.filtersOpen = true; render(); }
    else if (action === 'close-filters') { state.filtersOpen = false; render(); }
    else if (action === 'apply-filters') {
      state.minPages = app.querySelector('#minPages')?.value || ''; state.maxPages = app.querySelector('#maxPages')?.value || '';
      state.rating = app.querySelector('#filterRating')?.value || '不限'; state.category = app.querySelector('#filterCategory')?.value || '全部分类';
      state.filtersOpen = false; state.screen = 'discover'; render();
    } else if (action === 'saved-manager') { state.savedManagerOpen = true; render(); }
    else if (action === 'close-saved-manager') { state.savedManagerOpen = false; render(); }
    else if (action === 'save-open') { state.saveOriginId = state.loadedSavedId; state.saveName = state.saved.find((item) => item.id === state.saveOriginId)?.name || ''; state.saveOpen = true; render(); }
    else if (action === 'close-save') { state.saveOpen = false; render(); }
    else if (action === 'save-update') {
      const index = state.saved.findIndex((item) => item.id === state.saveOriginId);
      if (index >= 0) { const name = app.querySelector('#saveName')?.value.trim() || state.saved[index].name; state.saved[index] = captureSaved(name, state.saveOriginId); state.loadedSavedId = state.saveOriginId; }
      state.saveOpen = false; render();
    } else if (action === 'save-as-new') {
      const name = app.querySelector('#saveName')?.value.trim() || '未命名组合';
      const id = `saved-${++state.savedSerial}`; state.saved.push(captureSaved(name, id)); state.loadedSavedId = id;
      state.saveOpen = false; render();
    } else if (action === 'clear-search') { state.query = ''; state.tags = []; state.anyTags = []; state.excluded = []; state.titleOnly = false; state.category = '全部分类'; state.rating = '不限'; state.minPages = ''; state.maxPages = ''; state.loadedSavedId = null; state.screen = 'discover'; state.lane = 'latest'; render(); }
    else if (action === 'clear-text') { state.query = ''; const input = app.querySelector('#queryInput'); if (input) input.value = ''; updateSearchInput(''); }
    else if (action === 'bookmark') { const w = selected(); state.bookmarks.has(w.id) ? state.bookmarks.delete(w.id) : state.bookmarks.add(w.id); render(); }
    else if (action === 'download') { state.downloaded.add(selected().id); toast('已加入本机下载队列。完成的页面会长期保留。'); }
    else if (action === 'read') beginRead();
    else if (action === 'back') { state.screen = state.screen === 'reader' ? 'detail' : state.previousScreen; render(); }
    else if (action === 'pause') { state.downloading = !state.downloading; render(); }
    else if (action === 'tag-search') { const tag = state.tagDraft; if (!state.tags.includes(tag)) state.tags.push(tag); state.tagOpen = false; state.screen = 'discover'; toast(`已将 ${tag} 加入当前搜索。`); }
    else if (action === 'tag-pin') { state.pinned.add(state.tagDraft); state.tagOpen = false; toast(`已将 ${state.tagDraft} 加入常用标签。`); }
    else if (action === 'tag-block') { state.blocked.add(state.tagDraft); state.tagOpen = false; toast(`已屏蔽 ${state.tagDraft}；本机列表会隐藏对应作品。`); }
    else if (action === 'close-tag') { state.tagOpen = false; render(); }
    else if (action === 'next-page') { state.page = Math.min(selected().pages, state.page + 1); render(); }
    else if (action === 'prev-page') { state.page = Math.max(1, state.page - 1); render(); }
    else if (action === 'toggle-chrome') { state.readerChrome = !state.readerChrome; render(); }
    else if (action === 'thumbnails') { state.readerChrome = true; state.thumbnailsOpen = !state.thumbnailsOpen; render(); }
    else if (action === 'reader-settings') { state.readerChrome = true; state.settingsOpen = true; render(); }
    else if (action === 'account-manage') { state.accountOpen = true; render(); }
    else if (action === 'close-account') { state.accountOpen = false; render(); }
    else if (action === 'verify') toast('验证入口已就绪，可分别检查 E-Hentai 与 ExHentai。');
    else if (action === 'web-login') toast('请在站点官方登录页完成会话验证。');
    else if (action === 'logout') { state.accountOpen = false; state.loggedIn = false; toast('已退出站点账号。'); }
    else if (action === 'preferences') { state.prefsOpen = true; render(); }
    else if (action === 'close-prefs') { state.prefsOpen = false; render(); }
    else if (action === 'reading-settings') { state.settingsOpen = true; render(); }
    else if (action === 'close-settings') { state.settingsOpen = false; render(); }
    else if (action === 'reader-theme') { state.darkReader = !state.darkReader; render(); }
    else if (action === 'storage') { state.storageOpen = true; render(); }
    else if (action === 'close-storage') { state.storageOpen = false; render(); }
    else if (action === 'sponsor') { state.sponsorOpen = true; render(); }
    else if (action === 'close-sponsor') { state.sponsorOpen = false; render(); }
    else if (action === 'toast-close') { state.toast = ''; render(); }
  });

  render();
  window.setTimeout(() => { state.loaded = true; if (state.network === 'normal') render(); }, 950);
})();
