import { renderSettings, revealSettingsSection, performanceLimitedFps, showEnergyUsage, milliwatts, energyLevelLabel, batteryShare } from './settings.js';
import { createWelcome, SIGN_IN_ID } from './welcome.js';
import { glyphs } from './icons.js';
import { t, applyStaticText, setLanguage, language } from './i18n.js';
import { renderPropertyLabel } from './property-label.js';
import { createPixivPage } from './pixiv.js';
import { createSupportPrompt } from './support-prompt.js';
import { createCollections } from './collections.js';
import { createPresets } from './presets.js';
import { createPlacement } from './placement.js';
import { createCompatibility } from './compatibility.js';
import { createLetterbox } from './letterbox.js';

const $ = (id) => document.getElementById(id);
const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
// GitHub brand mark: kept from the original panel; Lucide ships no brand icons.
const brands = { github: '<path fill="currentColor" stroke="none" d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/>' };
brands.wallpaperMachine = '<path d="M12.273 20H17.4A3.6 3.6 0 0 0 21 16.4V6.6A3.6 3.6 0 0 0 17.4 3H7.6A3.6 3.6 0 0 0 4 6.6V11.727" stroke-width="2.9"/><path d="M9.706 18.1Q9.706 18.37 9.952 18.481L10.735 18.836Q11.121 19.011 10.959 19.403L10.398 20.756Q10.236 21.148 9.839 20.998L9.034 20.696Q8.782 20.601 8.592 20.792L8.592 20.792Q8.401 20.982 8.496 21.234L8.798 22.039Q8.948 22.436 8.556 22.598L7.203 23.159Q6.811 23.321 6.636 22.935L6.281 22.152Q6.17 21.906 5.9 21.906L5.9 21.906Q5.63 21.906 5.519 22.152L5.164 22.935Q4.989 23.321 4.597 23.159L3.244 22.598Q2.852 22.436 3.002 22.039L3.304 21.234Q3.399 20.982 3.208 20.792L3.208 20.792Q3.018 20.601 2.766 20.696L1.961 20.998Q1.564 21.148 1.402 20.756L0.841 19.403Q0.679 19.011 1.065 18.836L1.848 18.481Q2.094 18.37 2.094 18.1L2.094 18.1Q2.094 17.83 1.848 17.719L1.065 17.364Q0.679 17.189 0.841 16.797L1.402 15.444Q1.564 15.052 1.961 15.202L2.766 15.504Q3.018 15.599 3.208 15.408L3.208 15.408Q3.399 15.218 3.304 14.966L3.002 14.161Q2.852 13.764 3.244 13.602L4.597 13.041Q4.989 12.879 5.164 13.265L5.519 14.048Q5.63 14.294 5.9 14.294L5.9 14.294Q6.17 14.294 6.281 14.048L6.636 13.265Q6.811 12.879 7.203 13.041L8.556 13.602Q8.948 13.764 8.798 14.161L8.496 14.966Q8.401 15.218 8.592 15.408L8.592 15.408Q8.782 15.599 9.034 15.504L9.839 15.202Q10.236 15.052 10.398 15.444L10.959 16.797Q11.121 17.189 10.735 17.364L9.952 17.719Q9.706 17.83 9.706 18.1ZM7.49 18.1A1.59 1.59 0 1 0 4.31 18.1A1.59 1.59 0 1 0 7.49 18.1Z" fill="currentColor" stroke="none" fill-rule="evenodd"/>';
function icon(name, size = 16) { const px = Number(size) || 16; return `<svg width="${px}" height="${px}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${glyphs[name] || brands[name] || glyphs.info}</svg>`; }
const pending = new Set();
const drafts = new Map();
let state = null;
const inFlight = new Map();
let localError = '';
// Why applying a wallpaper last failed, by wallpaper id; the inspector offers to report it until an apply succeeds.
const activationFailures = new Map();
let popover = null;
let popoverTrigger = '';
let importWasBusy = false;
let importReportUnseen = false;
let queueExpanded = false;
let dialogTarget = null;
let dialogTrigger = null;
let dialogFocusKey = null;
// Job whose finished sign-in the dialog is confirming, and the timer that then lets it close on its own.
let dialogHandoff = null;
let handoffTimer = 0;
let workshopDraft = null;
let dialogAccount = null;
let dialogError = null;
// Password / Steam Guard requests the user closed with "Not now": keyed by job and request so the
// same request stays quiet while a new one still opens the dialog.
const dismissedAuth = new Set();
let searchTimer;
// Installed keeps Discover's filter model (required tags, excluded tags) and applies it in
// the page to each wallpaper's own tags: its manifest facts from the snapshot, its kind, and
// the page's Favorite / Active facts. Nothing is excluded by default: the library is the
// user's own, so every box starts ticked.
const installed = { text: '', sort: 'title', descending: false, tags: [], excludedTags: [] };
// Workshop sort keys mirror `WorkshopSort` raw values; Swift maps them to Steam's browse query.
// What Discover lists. An author's wallpapers and a collection's items are opened from a tile
// rather than chosen here, and come back to the list they were opened from.
const workshopSources = [['browse', 'Wallpapers', 'image'], ['collections', 'Collections', 'layers'], ['subscriptions', 'Your subscriptions', 'bookmark']];
const workshopSorts = [['toprated', 'Highest rated'], ['trend-today', 'Most popular today'], ['trend', 'Trending this week'], ['trend-month', 'Most popular this month'], ['trend-year', 'Most popular this year'], ['totaluniquesubscribers', 'Most subscribed'], ['mostrecent', 'Newest'], ['lastupdated', 'Recently updated'], ['textsearch', 'Relevance']];
// Installed sort keys with the direction each one starts in: names read A→Z, while favorites,
// size and date are asked for to see the biggest / newest / starred first.
const installedSorts = [['title', 'Name', false], ['type', 'Type', false], ['favorites', 'Favorites', true], ['size', 'File size', true], ['added', 'Date added', true]];
// Multi-select lives only in the page: ids of installed wallpapers checked for a batch action.
const selection = new Set();
let selectionAnchor = null;
let selecting = false; // Toolbar "Select" mode keeps every tile's check visible.
// A press-and-drag selection in progress on Installed (see `beginSweep`), and whether the click
// that ends it must be ignored because the press has already done its work.
let sweep = null;
let swallowClick = false;
// Wallpaper Engine's own Workshop sidebar, tag for tag. "Show only" boxes start unchecked and
// checking one sends the tag as `requiredtags[]`. Every other box starts checked and unchecking
// it sends the tag as `excludedtags[]`, so a group with everything ticked filters nothing.
// Entries are `tag` or `[tag, label, off]`; `off` marks the boxes Wallpaper Engine leaves
// unchecked by default. Application and Asset are never offered, so they are always excluded.
const showOnlyTags = ['Approved', 'Audio responsive', 'Customizable'];
// Installed leads with the two facts only a library has, then Discover's three.
const installedShowOnlyTags = ['Favorite', 'Active', 'Update', ...showOnlyTags];
const showOnlyLabels = { Favorite: 'Favorites', Active: 'Active on target display', Update: 'Update available' };
// Approved keeps Wallpaper Engine's green trophy so the mark matches what users know from Workshop.
const showOnlyIcons = { Approved: 'trophy', 'Audio responsive': 'audioLines', Customizable: 'slidersVertical', Favorite: 'heart', Active: 'play', Update: 'download' };
const hiddenExcludedTags = ['Application', 'Asset'];
const resolutionSection = (key, title, prefix, sizes) => ({ key, title, quick: true, tags: [[`${prefix}Standard Definition`, prefix ? `${title} (standard)` : 'Standard definition'], ...sizes.map(size => [`${prefix}${size}`, size])] });
// `discoverOnly` marks what Steam knows but a wallpaper's manifest does not carry (its
// Workshop category and resolution), so Installed leaves those boxes out.
const excludeGroups = [
  { key: 'type', title: 'Type', sections: [{ key: 'type', tags: ['Scene', 'Video', 'Web'] }, { key: 'category', discoverOnly: true, tags: ['Wallpaper', 'Preset'] }] },
  { key: 'rating', title: 'Age rating', sections: [{ key: 'rating', tags: [['Everyone', 'Everyone (G)'], ['Questionable', 'Questionable (PG-13)', true], ['Mature', 'Mature (R-18)', true]] }] },
  { key: 'resolution', title: 'Resolution', discoverOnly: true, sections: [
    resolutionSection('widescreen', 'Widescreen', '', ['1280 x 720', '1366 x 768', '1920 x 1080', '2560 x 1440', '3840 x 2160']),
    resolutionSection('ultrawide', 'Ultrawide', 'Ultrawide ', ['2560 x 1080', '3440 x 1440']),
    resolutionSection('dual', 'Dual monitor', 'Dual ', ['3840 x 1080', '5120 x 1440', '7680 x 2160']),
    resolutionSection('triple', 'Triple monitor', 'Triple ', ['4096 x 768', '5760 x 1080', '7680 x 1440', '11520 x 2160']),
    resolutionSection('portrait', 'Portrait monitor / phone', 'Portrait ', ['720 x 1280', '1080 x 1920', '1440 x 2560', '2160 x 3840']),
    { key: 'other-resolution', tags: ['Other resolution', 'Dynamic resolution'] }
  ] },
  { key: 'genre', title: 'Tags', sections: [{ key: 'genre', quick: true, tags: ['Abstract', 'Animal', 'Anime', 'Cartoon', 'CGI', 'Cyberpunk', 'Fantasy', 'Game', 'Girls', 'Guys', 'Landscape', 'Medieval', 'Memes', ['MMD', 'MMD (Miku Miku Dance)'], 'Music', 'Nature', 'Pixel art', 'Relaxing', 'Retro', 'Sci-Fi', 'Sports', 'Technology', 'Television', 'Vehicle', ['Unspecified', 'Unspecified genre', true]] }] }
];
const tagEntry = (entry) => Array.isArray(entry) ? { tag: entry[0], label: entry[1] || entry[0], off: Boolean(entry[2]) } : { tag: entry, label: entry, off: false };
const excludeSections = excludeGroups.flatMap(group => group.sections);
const excludeEntries = excludeSections.flatMap(section => section.tags.map(tagEntry));
const defaultExcludedTags = [...hiddenExcludedTags, ...excludeEntries.filter(entry => entry.off).map(entry => entry.tag)];
const installedGroups = excludeGroups.filter(group => !group.discoverOnly).map(group => ({ ...group, sections: group.sections.filter(section => !section.discoverOnly) }));
const genreTags = excludeGroups.find(group => group.key === 'genre').sections[0].tags.map(tagEntry).filter(entry => entry.tag !== 'Unspecified').map(entry => entry.tag.toLowerCase());
const uniqueTags = (values) => [...new Set(values)];
// The page's filter draft and its defaults: Discover's are Wallpaper Engine's, Installed's are empty.
const filterDraft = (discover) => discover ? workshopDraft : installed;
const filterDefaults = (discover) => discover ? defaultExcludedTags : [];
const actionKey = (action, args = {}) => `${action}:${args.id ?? ''}:${args.displayID ?? ''}:${args.propertyID ?? args.key ?? ''}`;
const busy = (action, args = {}) => pending.has(actionKey(action, args));
const disabled = (value) => value ? ' disabled' : '';
const checked = (value) => value ? ' checked' : '';
const keyAttr = (value) => `data-key="${escapeHTML(value)}"`;
function button(label, action, args = {}, options = {}) {
  const attributes = Object.entries(args).map(([key, value]) => `data-${key.replace(/ID$/, 'Id').replace(/[A-Z]/g, c => `-${c.toLowerCase()}`)}="${escapeHTML(typeof value === 'object' ? JSON.stringify(value) : value)}"`).join(' ');
  return `<button type="button" data-action="${action}" ${attributes} class="${options.className || ''}"${disabled(options.disabled || busy(action, args))}${options.title ? ` title="${escapeHTML(options.title)}" aria-label="${escapeHTML(options.title)}"` : ''}${options.expanded !== undefined ? ` aria-expanded="${options.expanded ? 'true' : 'false'}"` : ''}${options.controls ? ` aria-controls="${escapeHTML(options.controls)}"` : ''}>${options.icon ? icon(options.icon) : ''}${label ? `<span class="button-label">${escapeHTML(label)}</span>` : ''}</button>`;
}
// A control's frame in the page, for a native menu that opens next to it.
function elementRect(element) {
  const box = element?.getBoundingClientRect?.() || { x: 0, y: 0, width: 0, height: 0 };
  return { x: box.x, y: box.y, width: box.width, height: box.height };
}
function selectOptions(values, current) { return values.map((entry) => { const [value, label] = Array.isArray(entry) ? entry : [entry, entry]; return `<option value="${escapeHTML(value)}"${String(current) === String(value) ? ' selected' : ''}>${escapeHTML(label)}</option>`; }).join(''); }
function safeLink(url) { if (!url) return ''; try { const parsed = new URL(url); return parsed.protocol === 'https:' ? parsed.href : ''; } catch { return ''; } }
function safeImage(url) { if (!url) return ''; try { const parsed = new URL(url); return ['https:', 'mwe-ui:'].includes(parsed.protocol) ? parsed.href : ''; } catch { return ''; } }
function preview(url, className = '') { const source = safeImage(url); return `${icon('image', 32)}${source ? `<img ${keyAttr(source)} class="${className}" src="${escapeHTML(source)}" alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer">` : ''}`; }
function tags(values = []) { return `<div class="tags">${values.map(value => `<span class="tag">${escapeHTML(value)}</span>`).join('')}</div>`; }
function bytes(value) { if (!Number.isFinite(value) || value <= 0) return ''; const units = ['B', 'KB', 'MB', 'GB']; const exponent = Math.min(Math.floor(Math.log(value) / Math.log(1024)), 3); return `${(value / 1024 ** exponent).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[exponent]}`; }
function speed(value) {
  if (!Number.isFinite(value) || value < 0) return '';
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  const exponent = value > 0 ? Math.min(Math.max(Math.floor(Math.log10(value) / 3), 0), 3) : 0;
  return `${(value / 1000 ** exponent).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[exponent]}`;
}
function rate(value) { const pace = speed(value); return pace ? t('Network speed: {speed}', { speed: pace }) : ''; }
// Seconds under a minute and a half, minutes under an hour and a half, then hours with one decimal.
function duration(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return '';
  const [value, unit] = seconds < 90 ? [Math.round(seconds), 'second'] : seconds < 5400 ? [Math.round(seconds / 60), 'minute'] : [Math.round(seconds / 360) / 10, 'hour'];
  try { return new Intl.NumberFormat(language(), { style: 'unit', unit, unitDisplay: 'short', maximumFractionDigits: 1 }).format(value); } catch { return ''; }
}
function timeLeft(seconds) { const time = duration(seconds); return time ? t('{time} left', { time }) : ''; }
function transfer(item, { includePercent = true } = {}) { const percent = Number.isFinite(item?.progress) ? `${Math.round(clamp(item.progress) * 100)}%` : ''; const received = bytes(item?.bytesReceived); const expected = bytes(item?.bytesExpected); const amount = received && expected ? t('{received} of {expected}', { received, expected }) : received; return [includePercent ? percent : '', amount, rate(item?.bytesPerSecond), timeLeft(item?.secondsRemaining)].filter(Boolean).join(' · '); }

// Keyed reconciliation keeps loaded preview images, open disclosures and active fields alive.
function morph(parent, html) {
  const template = document.createElement('template'); template.innerHTML = html;
  reconcile(parent, template.content);
}
function reconcile(parent, source) {
  const old = [...parent.childNodes];
  const keys = new Map(old.filter(node => node.nodeType === 1 && node.dataset.key).map(node => [node.dataset.key, node]));
  const used = new Set();
  let cursor = parent.firstChild;
  for (const fresh of [...source.childNodes]) {
    let node = fresh.nodeType === 1 && fresh.dataset.key ? keys.get(fresh.dataset.key) : old.find(candidate => !used.has(candidate) && !(candidate.nodeType === 1 && candidate.dataset.key) && candidate.nodeType === fresh.nodeType && candidate.nodeName === fresh.nodeName);
    if (!node || node.nodeName !== fresh.nodeName) { node = fresh.cloneNode(true); parent.insertBefore(node, cursor); }
    else { if (node !== cursor) parent.insertBefore(node, cursor); patch(node, fresh); }
    used.add(node); cursor = node.nextSibling;
  }
  for (const node of old) if (!used.has(node)) node.remove();
}
function patch(node, fresh) {
  if (node.nodeType === 3) { if (node.nodeValue !== fresh.nodeValue) node.nodeValue = fresh.nodeValue; return; }
  if (node.nodeType !== 1) return;
  const focused = node === document.activeElement;
  for (const attribute of [...node.attributes]) {
    if (attribute.name === 'open' && node.tagName === 'DETAILS') continue;
    if (!fresh.hasAttribute(attribute.name) && !(focused && ['value', 'checked'].includes(attribute.name))) node.removeAttribute(attribute.name);
  }
  for (const attribute of [...fresh.attributes]) {
    if (attribute.name === 'open' && node.tagName === 'DETAILS') continue;
    if (focused && ['value', 'checked'].includes(attribute.name)) continue;
    if (node.getAttribute(attribute.name) !== attribute.value) node.setAttribute(attribute.name, attribute.value);
  }
  // Secrets are never part of the markup, so a password field keeps what was typed across renders.
  if (node.tagName === 'INPUT') { if (!focused) { if (node.name !== 'password' && node.name !== 'response' && node.type !== 'password' && node.value !== fresh.value) node.value = fresh.value; node.checked = fresh.checked; } return; }
  if (node.tagName === 'TEXTAREA') { if (!focused && node.value !== fresh.value) node.value = fresh.value; return; }
  if (node.tagName === 'SELECT' && focused) return;
  reconcile(node, fresh);
  if (node.tagName === 'SELECT') node.value = fresh.value;
}

async function send(action, args = {}) {
  const bridge = window.webkit?.messageHandlers?.native;
  if (!bridge) { localError = t('The native connection is unavailable. Open this panel in WallpaperMachine, then reconnect.'); renderError(); throw new Error(localError); }
  const key = actionKey(action, args);
  if (pending.has(key)) {
    if (['property', 'wallpaperSetting', 'displayConfig', 'displayPosition', 'workshopSearch', 'pixivSearch', 'navigate', 'target'].includes(action)) {
      // The earlier request reported its own failure; this newer value is still sent.
      await inFlight.get(key)?.catch(() => {});
      return send(action, args);
    }
    return state;
  }
  pending.add(key); localError = '';
  // The busy render belongs inside the try: a render that threw here once left the key
  // pending with nothing in flight, and the next send of a queued action awaited that
  // missing request and re-sent itself in an endless microtask loop that froze the page.
  try {
    render();
    const request = bridge.postMessage({ action, ...args });
    inFlight.set(key, request);
    const response = await request;
    if (response && typeof response === 'object') receive(response);
    return response;
  } catch (error) {
    localError = error?.message || String(error); renderError(); throw error;
  } finally { pending.delete(key); inFlight.delete(key); render(); }
}
async function sendDialog(action, args = {}) {
  const account = dialogAccount;
  dialogError = null;
  try {
    return await send(action, args);
  } catch (error) {
    if (account === dialogAccount && dialogTarget !== null) {
      dialogError = { account, message: error?.message || String(error) };
      renderDialog();
    }
    throw error;
  }
}
function receive(snapshot) {
  if (!snapshot || typeof snapshot !== 'object') return;
  if (!Array.isArray(snapshot.wallpapers)) {
    if (!snapshot.libraryRevision || state?.libraryRevision !== snapshot.libraryRevision
        || !Array.isArray(state.wallpapers)) return 'needsFullSnapshot';
    snapshot = { ...snapshot, wallpapers: state.wallpapers };
  }
  if (snapshot.import?.busy) importReportUnseen = false;
  else if (importWasBusy && snapshot.import?.report) importReportUnseen = popover !== 'import';
  importWasBusy = Boolean(snapshot.import?.busy);
  if (popover === 'import' && !snapshot.import?.busy && !snapshot.import?.report && state?.import?.report) {
    snapshot = { ...snapshot, import: { ...snapshot.import, report: state.import.report } };
  }
  state = snapshot;
  if (selection.size) { const ids = new Set((snapshot.wallpapers || []).map(item => item.id)); for (const id of selection) if (!ids.has(id)) selection.delete(id); }
  if (selectionAnchor && !selection.has(selectionAnchor)) selectionAnchor = null;
  // Page-side choices that name something in the snapshot (a collection on show, a picked
  // preset, a placement being dragged) follow what the snapshot still has.
  collections.sync(snapshot); presets.sync(snapshot); placement.sync(snapshot); compatibilityCard.sync(snapshot); letterbox.sync(snapshot);
  window.appTheme.apply(snapshot.theme);
  // Every string is translated where it is drawn, so a language change only needs the
  // static markup refreshed before the render below redraws the rest.
  const shown = language();
  if (snapshot.language?.effective && setLanguage(snapshot.language.effective) !== shown) applyStaticText();
  if (!workshopDraft) workshopDraft = { text: snapshot.workshop?.text || '', sort: snapshot.workshop?.sort || 'trend-year', tags: [...(snapshot.workshop?.tags || [])], excludedTags: [...(snapshot.workshop?.excludedTags || defaultExcludedTags)] };
  viewState.begin(snapshot);
  // The first-run guide opens from the first snapshot that reports it unseen and closes for
  // good once the user finishes or leaves it; a snapshot that arrives before native has
  // stored that choice cannot reopen it.
  if (snapshot.welcomeSeen === false) welcome.openIfUndecided();
  render();
  viewState.applyScroll();
}
window.wallpaperUI = { receive, energy: showEnergyUsage };
// A sentence for screen readers about something that changed without moving focus; the text is
// cleared first so the same sentence twice is read twice.
function announce(text) { const node = $('announcer'); node.textContent = ''; node.textContent = text; }
function renderError() {
  const error = localError || state?.error || state?.downloadError;
  if (!state && error) morph($('browser-empty'), `<h1>${escapeHTML(t('Native connection unavailable'))}</h1><p>${escapeHTML(t('Open this panel in WallpaperMachine. Use Reconnect above to try again.'))}</p>`);
  $('error-banner').hidden = !error;
  if (error) morph($('error-banner'), `<p>${escapeHTML(error)}</p>${!state || !window.webkit?.messageHandlers?.native ? button(t('Reconnect'), 'ready', {}, { icon: 'refresh' }) : ''}${button('', 'dismissError', {}, { icon: 'close', title: t('Dismiss error'), className: 'quiet icon-button' })}`);
}
// Wallpapers the app left out of this session because it quit unexpectedly twice while loading
// them. Native words each message; Try again opens that wallpaper and lifts the hold. A failed
// retry reaches the error banner above and the row stays.
function renderHeld() {
  const held = Array.isArray(state?.held) ? state.held : [];
  $('held-banner').hidden = !held.length;
  if (held.length) morph($('held-banner'), held.map(item => `<div class="held-row" ${keyAttr(`held-${item.id}`)}><p>${escapeHTML(item.message)}</p>${button(t('Try again'), 'releaseHeld', { id: item.id }, { icon: 'refresh' })}</div>`).join(''));
}
function render() {
  renderError();
  renderHeld();
  if (!state) return;
  const discover = state.page === 'discover';
  const settings = state.page === 'settings';
  const pixivPage = state.page === 'pixiv';
  if (livePage !== state.page) { releaseLivePreviews(); livePage = state.page; }
  document.querySelectorAll('.tabs [data-page]').forEach(tab => { if (tab.dataset.page === state.page) tab.setAttribute('aria-current', 'page'); else tab.removeAttribute('aria-current'); });
  document.documentElement.style.setProperty('--window-controls-inset', `${Math.max(0, Number(state.windowControlsInset) || 0)}px`);
  morph($('app-identity'), `<span class="app-brand-mark">${icon('wallpaperMachine', 22)}</span><span class="app-title"><span class="app-name">WallpaperMachine</span></span>`);
  morph($('top-actions'), `<label class="sr-only" for="target-display">${escapeHTML(t('Target display'))}</label><select id="target-display" data-change="target" aria-label="${escapeHTML(t('Target display'))}"${disabled(state.busy)}>${(state.displays || []).map(display => `<option value="${escapeHTML(display.id)}"${display.id === state.targetDisplayID ? ' selected' : ''}${disabled(!display.enabled || display.mode === 'mirror')}>${escapeHTML(display.title)}${display.mode === 'mirror' ? escapeHTML(t(' (mirrored)')) : !display.enabled ? escapeHTML(t(' (disabled)')) : ''}</option>`).join('')}</select>${queueButton()}`);
  $('library-page').hidden = settings;
  $('settings-content').hidden = !settings;
  if (settings) renderSettings($('settings-content'), state, { send, escapeHTML, icon, requestAssets: (element) => run(requestDownload(null, element)), openDownloadDialog: (id, element) => openDialog(id, element), openWelcome: () => welcome.open() });
  else {
    // Both library pages share one right-hand filter sidebar; the toolbar's Filter button
    // opens and closes it, and each page remembers its own choice natively.
    const filtersOpen = !filtersCollapsed();
    $('library-page').classList.toggle('discover', discover);
    $('library-page').classList.toggle('filters-open', filtersOpen);
    $('filter-sidebar').hidden = !filtersOpen;
    if (pixivPage) pixiv.render(state, filtersOpen);
    else {
      renderToolbar(discover);
      if (filtersOpen) renderFilters(discover);
      renderGrid(discover);
      renderInspector(discover);
    }
  }
  renderActivity(); renderPopover(); renderDialog(); welcome.render(state); surfaceAuthRequests(); supportPrompt.render(state);
  viewState.touch();
}
const filtersCollapsed = () => Boolean(state?.filtersCollapsed?.[state.page]);
// Active filters on a page: every required tag plus every box that differs from the page's
// defaults, so the count reads zero right after Clear.
function filterCount(discover) {
  const draft = filterDraft(discover), defaults = filterDefaults(discover);
  return draft.tags.length + defaults.filter(tag => !draft.excludedTags.includes(tag)).length + draft.excludedTags.filter(tag => !defaults.includes(tag)).length + (!discover && collections.active() ? 1 : 0);
}
const filterCountPill = (count) => count ? `<span class="filter-count" title="${escapeHTML(t('{count} active', { count }))}">${count}</span>` : '';
// The one control that opens and closes the sidebar: a filled button so it reads as the
// place to go, a funnel so it reads as filtering, and the active count riding along. It
// leads the toolbar so it sits right beside the sidebar it controls.
function filterButton(count) {
  const open = !filtersCollapsed();
  return `<button type="button" data-action="toggleFilters" class="filter-button" aria-expanded="${open}" aria-controls="filter-sidebar" title="${escapeHTML(open ? t('Hide filters') : t('Show filters'))}"${disabled(busy('filters'))}>${icon('filter')}<span class="button-label">${escapeHTML(t('Filter'))}</span>${filterCountPill(count)}</button>`;
}
// Discover's source: one of Steam's lists, chosen from tabs above the toolbar so each reads as a
// place to go (subscriptions went unnoticed as the last entry of a menu), or the author or
// collection opened from a tile, with the way back to where it was opened. An opened one leaves
// every tab unselected. Only Steam's own lists are searched and sorted.
const workshopSource = () => state.workshop?.source || { key: 'browse', searchable: true, canGoBack: false };
const openedSource = (source) => ['creator', 'collection'].includes(source.key);
function sourceHeading(source) {
  if (source.key === 'creator') return source.name ? t('Wallpapers by {name}', { name: source.name }) : t('This author’s wallpapers');
  return source.name ? t('Collection: {title}', { title: source.name }) : t('Collection');
}
function sourceTabs(source) {
  return `<nav class="source-tabs" aria-label="${escapeHTML(t('Workshop lists'))}">${workshopSources.map(([key, label, glyph]) => `<button type="button" data-action="workshopSource" data-source="${key}"${key === source.key ? ' aria-current="page"' : ''}>${icon(glyph, 15)}<span>${escapeHTML(t(label))}</span></button>`).join('')}</nav>`;
}
function sourceBar(source) {
  if (!openedSource(source)) return '';
  return `<div class="source-bar">${button('', 'workshopBack', {}, { icon: 'chevronLeft', title: t('Go back'), className: 'quiet icon-button', disabled: !source.canGoBack || state.workshop.loading })}<h2 class="source-title" title="${escapeHTML(sourceHeading(source))}">${escapeHTML(sourceHeading(source))}</h2></div>`;
}
function renderToolbar(discover) {
  const search = discover ? workshopDraft.text : installed.text;
  const sortLabel = t(installedSorts.find(([key]) => key === installed.sort)?.[1] || 'Name');
  const source = discover ? workshopSource() : null;
  const searchable = !discover || source.searchable !== false;
  const sortPicker = searchable ? `<label class="sr-only" for="browser-sort">${escapeHTML(t('Sort wallpapers'))}</label><select id="browser-sort" data-change="sort">${selectOptions((discover ? workshopSorts : installedSorts).map(([key, label]) => [key, t(label)]), discover ? workshopDraft.sort : installed.sort)}</select>` : '';
  morph($('browser-toolbar'), `${discover ? sourceTabs(source) : ''}${filterButton(filterCount(discover))}${discover ? sourceBar(source) : ''}${searchable ? `<form class="search-form" data-form="search" ${keyAttr(discover ? 'workshop-search' : 'installed-search')}>${icon('search')}<label class="sr-only" for="wallpaper-search">${escapeHTML(discover ? t('Search Steam Workshop') : t('Search installed wallpapers'))}</label><input id="wallpaper-search" type="search" autocomplete="off" placeholder="${escapeHTML(discover ? (source.key === 'browse' ? t('Search Workshop or paste a link') : t('Search Workshop')) : t('Search wallpapers'))}" value="${escapeHTML(search)}" data-input="search">${discover ? `<button type="submit" title="${escapeHTML(t('Search Workshop'))}">${escapeHTML(t('Search'))}</button>` : ''}</form>` : ''}<div class="toolbar-tools">${sortPicker}${discover ? `${button('', 'refreshWorkshop', {}, { icon: 'refresh', title: t('Refresh Workshop'), disabled: state.workshop.loading })}` : `${button('', 'toggleSortDirection', {}, { icon: installed.descending ? 'sortDescending' : 'sortAscending', title: installed.descending ? t('{sort}, descending. Click to sort ascending', { sort: sortLabel }) : t('{sort}, ascending. Click to sort descending', { sort: sortLabel }), className: 'icon-button sort-direction' })}${button(selecting ? t('Done') : t('Select'), 'toggleSelecting', {}, { icon: selecting ? 'close' : 'check', title: selecting ? t('Leave selection mode') : t('Select wallpapers to move to Trash. Holding a tile and dragging across others selects them too.'), className: selecting ? 'selecting' : '' })}${button('', 'refresh', {}, { icon: 'refresh', title: t('Refresh library'), disabled: state.libraryLoading })}${button(t('Import'), 'openImport', {}, { icon: 'plus', className: 'import-button', title: t('Import wallpapers'), disabled: state.import?.busy })}`}</div>`);
}
const filterGroup = (key, title, body, open, count = 0) => `<details class="filter-group"${open ? ' open' : ''} ${keyAttr(key)}><summary><span class="filter-group-title">${escapeHTML(t(title))}${filterCountPill(count)}</span>${icon('chevronRight', 13)}</summary><div class="filter-options">${body}</div></details>`;
const filterHeading = (count, clearAction) => `<div class="filter-heading"><h3>${escapeHTML(t('Filters'))}${filterCountPill(count)}</h3>${button(t('Clear'), clearAction, {}, { className: 'link', disabled: !count })}</div>`;
// One sidebar for both pages: Discover's boxes go to Steam as `requiredtags[]` /
// `excludedtags[]`; Installed's apply the same rules to the library in the page.
function renderFilters(discover) {
  const draft = filterDraft(discover);
  const defaults = filterDefaults(discover);
  const groupCount = group => group.sections.flatMap(section => section.tags.map(tagEntry)).filter(({ tag }) => draft.excludedTags.includes(tag) !== defaults.includes(tag)).length;
  const showOnly = discover ? showOnlyTags : installedShowOnlyTags;
  // Tags travel to Steam in English; only their labels are translated.
  const required = (tag) => `<label class="check-label" ${keyAttr(tag)}><input type="checkbox" data-change="filterTag" value="${escapeHTML(tag)}"${checked(draft.tags.includes(tag))}>${showOnlyIcons[tag] ? `<span class="check-icon${tag === 'Approved' ? ' approved' : ''}">${icon(showOnlyIcons[tag], 14)}</span>` : ''}<span>${escapeHTML(t(showOnlyLabels[tag] || tag))}</span></label>`;
  const other = draft.tags.filter(tag => !showOnly.includes(tag));
  const section = ({ key, title, quick, tags: entries }) => {
    const values = entries.map(tagEntry);
    const onCount = values.filter(({ tag }) => !draft.excludedTags.includes(tag)).length;
    const head = title || quick ? `<div class="filter-section-head">${title ? `<h4>${escapeHTML(t(title))}</h4>` : ''}${quick ? `<span class="filter-quick">${button(t('All'), 'includeSection', { section: key }, { className: 'link', disabled: onCount === values.length })}${button(t('None'), 'excludeSection', { section: key }, { className: 'link', disabled: onCount === 0 })}</span>` : ''}</div>` : '';
    return `<div class="filter-section" ${keyAttr(key)}>${head}${values.map(({ tag, label }) => `<label class="check-label" ${keyAttr(tag)}><input type="checkbox" data-change="filterExclude" value="${escapeHTML(tag)}"${checked(!draft.excludedTags.includes(tag))}><span>${escapeHTML(t(label))}</span></label>`).join('')}</div>`;
  };
  morph($('filter-sidebar'), `${filterHeading(filterCount(discover), discover ? 'clearWorkshop' : 'clearInstalled')}${discover ? '' : collections.sidebarGroup()}${filterGroup('show-only', 'Show only', `${showOnly.map(tag => required(tag)).join('')}${other.length ? `<div class="filter-section" ${keyAttr('other')}><div class="filter-section-head"><h4>${escapeHTML(t('Other selected tags'))}</h4></div>${other.map(tag => required(tag)).join('')}</div>` : ''}`, true, draft.tags.length)}${(discover ? excludeGroups : installedGroups).map(group => filterGroup(group.key, group.title, group.sections.map(section).join(''), true, groupCount(group))).join('')}`);
}
function setExcluded(draft, tags, excluded) {
  const set = new Set(draft.excludedTags);
  for (const tag of tags) if (excluded) set.add(tag); else set.delete(tag);
  draft.excludedTags = [...set];
}
// Ticking a box on the current page: Discover asks Steam again, Installed re-filters in place.
function applyFilterChange() {
  render();
  return state.page === 'discover' ? searchWorkshop() : Promise.resolve();
}
// Everything an installed wallpaper can be filtered on, lower-cased for matching: the
// manifest's tags from the snapshot, the kind as Steam's type tag, the page's own Favorite
// and Active facts, and `Unspecified` when no genre was tagged, as Steam would list it.
function installedTags(item, target) {
  const tags = [item.kind, ...(item.tags || [])].map(tag => String(tag).toLowerCase());
  if (item.approved) tags.push('approved');
  if (state.favorites.includes(item.id)) tags.push('favorite');
  if (target?.wallpaperID === item.id) tags.push('active');
  if (item.updateAvailable) tags.push('update');
  if (!tags.some(tag => genreTags.includes(tag))) tags.push('unspecified');
  return new Set(tags);
}
function matchesInstalledFilters(item, target) {
  const tags = installedTags(item, target);
  return installed.tags.every(tag => tags.has(tag.toLowerCase())) && !installed.excludedTags.some(tag => tags.has(tag.toLowerCase()));
}
// Installed sorts in the page: a primary key in the chosen direction, names breaking ties.
// Wallpapers whose size or date has not been measured yet sort last either way.
const byTitle = (a, b) => a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: 'base' });
function sortValue(item) {
  switch (installed.sort) {
    case 'favorites': return Number(state.favorites.includes(item.id));
    case 'size': return Number.isFinite(item.size) ? item.size : null;
    case 'added': return Number.isFinite(item.addedAt) ? item.addedAt : null;
    default: return null;
  }
}
function compareInstalled(a, b) {
  const direction = installed.descending ? -1 : 1;
  if (installed.sort === 'title') return byTitle(a, b) * direction;
  if (installed.sort === 'type') return a.kind.localeCompare(b.kind) * direction || byTitle(a, b);
  const left = sortValue(a), right = sortValue(b);
  if (left === null || right === null) return (left === null) - (right === null) || byTitle(a, b);
  return (left - right) * direction || byTitle(a, b);
}
function visibleWallpapers() {
  const target = (state.displays || []).find(display => display.id === state.targetDisplayID);
  return (state.wallpapers || []).filter(item => collections.matches(item) && (!installed.text || `${item.title} ${(item.tags || []).join(' ')}`.toLocaleLowerCase().includes(installed.text.toLocaleLowerCase())) && matchesInstalledFilters(item, target)).sort(compareInstalled);
}
// Installed's filters and each library page's scroll offset outlive the window. The page
// reports them to native as they change (nothing comes back), and native hands them over with
// the reply to a new page's first `ready`, so a reopened panel resumes where it was closed.
// Native keeps them in memory only, so a fresh launch starts clean. Property drafts are left out:
// one restored against a library that changed in between could be delivered stale.
const viewState = (() => {
  const pages = ['installed', 'discover', 'pixiv']; // The pages that draw into #wallpaper-grid.
  const scroll = {};
  let armed = false, dirty = false, timer = 0, dueAt = 0, pendingScroll = null, seenFilters = '', seenText = '';
  const grid = () => $('wallpaper-grid');
  const onLibrary = () => Boolean(state) && pages.includes(state.page) && !$('library-page').hidden;
  // Native refuses text past 200 characters; no text is a more honest restore than a cut one.
  const filters = () => ({ text: installed.text.length <= 200 ? installed.text : '', sort: installed.sort, descending: installed.descending, tags: installed.tags, excludedTags: installed.excludedTags });
  function flush() {
    clearTimeout(timer); timer = 0;
    if (!dirty) return;
    dirty = false;
    if (onLibrary()) scroll[state.page] = Math.max(0, Math.round(grid().scrollTop));
    const bridge = window.webkit?.messageHandlers?.native;
    if (bridge) Promise.resolve(bridge.postMessage({ action: 'viewState', installed: filters(), scroll })).catch(() => {});
  }
  // The earliest deadline wins, so a burst of scrolling or typing reports at most once per delay.
  function schedule(delay) {
    if (!armed) return;
    dirty = true;
    const due = Date.now() + delay;
    if (timer && due >= dueAt) return;
    clearTimeout(timer); dueAt = due; timer = setTimeout(flush, delay);
  }
  // A required tag that nothing in the library carries any more would leave the grid empty.
  // Excluded tags stay: they only hide, and a wallpaper imported later should stay hidden.
  function dropStaleTags(snapshot) {
    if (!installed.tags.length || snapshot.libraryLoading || !snapshot.wallpapers?.length) return;
    const target = (snapshot.displays || []).find(display => display.id === snapshot.targetDisplayID);
    const carried = new Set();
    for (const item of snapshot.wallpapers) for (const tag of installedTags(item, target)) carried.add(tag);
    installed.tags = installed.tags.filter(tag => carried.has(tag.toLowerCase()));
  }
  // Runs on the first full snapshot, with `state` already set: later snapshots, and a second
  // `ready` from Reconnect, never overwrite what the person has done since.
  function begin(snapshot) {
    if (armed) return;
    armed = true;
    const saved = snapshot.restoreViewState;
    if (saved?.installed) {
      const filter = saved.installed;
      installed.text = String(filter.text ?? '');
      if (installedSorts.some(([key]) => key === filter.sort)) installed.sort = filter.sort;
      installed.descending = Boolean(filter.descending);
      installed.tags = uniqueTags((filter.tags || []).map(String));
      installed.excludedTags = uniqueTags((filter.excludedTags || []).map(String));
      dropStaleTags(snapshot);
      Object.assign(scroll, saved.scroll);
      pendingScroll = Number.isFinite(saved.scroll?.[snapshot.page]) ? saved.scroll[snapshot.page] : null;
    }
    seenFilters = JSON.stringify(filters()); seenText = installed.text;
  }
  // After the render that drew the restored grid; the offset is clamped to what the grid holds.
  function applyScroll() {
    if (pendingScroll === null) return;
    const offset = pendingScroll; pendingScroll = null;
    if (!onLibrary()) return;
    const element = grid();
    element.scrollTop = Math.min(offset, Math.max(0, element.scrollHeight - element.clientHeight));
  }
  // Typing reports once it pauses; a click on a box or the sort menu reports at once, so closing
  // the window right after it keeps the choice.
  function touch() {
    if (!armed) return;
    const key = JSON.stringify(filters());
    if (key === seenFilters) return;
    schedule(installed.text === seenText ? 0 : 400);
    seenFilters = key; seenText = installed.text;
  }
  grid().addEventListener('scroll', () => schedule(400), { passive: true });
  document.addEventListener('visibilitychange', () => { if (document.hidden) flush(); });
  window.addEventListener('pagehide', flush);
  return { begin, applyScroll, touch };
})();
function emptyRecovery(discover) {
  // A source Steam does not search ignores the search text, so only filters can hide its items.
  const draft = discover && workshopSource().searchable === false ? { ...filterDraft(discover), text: '' } : filterDraft(discover);
  const count = filterCount(discover);
  if (!discover && !state.wallpapers.length) return {
    description: t('Import a wallpaper folder or find something on the Workshop.'),
    actions: `${button(t('Import wallpapers'), 'openImport', {}, { icon: 'plus' })}${button(t('Browse Workshop'), 'navigate', { page: 'discover' }, { className: 'primary' })}`,
  };
  // An empty collection is empty, not filtered away.
  const emptyCollection = discover ? null : collections.emptyState();
  if (emptyCollection) return emptyCollection;
  if (draft.text && count) return {
    description: discover ? t('Try a different search or remove some filters. Every selected tag must match.') : t('Change your search or clear filters to see more wallpapers.'),
    actions: button(t('Clear search and filters'), discover ? 'clearWorkshopSearch' : 'clearInstalledSearch'),
  };
  if (draft.text) return {
    description: discover ? t('Try a different search or remove some filters. Every selected tag must match.') : t('No wallpaper title or tag contains “{text}”.', { text: draft.text }),
    actions: button(t('Clear search'), discover ? 'clearWorkshopSearch' : 'clearInstalledSearch'),
  };
  if (count) return {
    description: t(count === 1 ? 'The active filter hides every wallpaper.' : 'The {count} active filters hide every wallpaper.', { count }),
    actions: button(t('Clear filters'), discover ? 'clearWorkshop' : 'clearInstalled') + (filtersCollapsed() ? button(t('Show filters'), 'toggleFilters') : ''),
  };
  // Subscriptions, an author's or a collection's wallpapers, and collections while a rating is
  // hidden, are screened here, not by Steam, so the boxes can hide a whole page even at their
  // defaults; later pages may still hold some.
  const workshop = state.workshop || {};
  const screened = workshopSource().searchable === false || workshopSource().key === 'collections';
  if (discover && screened && Number(workshop.totalCount) > 0) return {
    description: workshopSource().key === 'collections' ? t('The age rating filters hide every collection found for this page.') : t('The age rating and type filters hide every wallpaper on this page.'),
    actions: (Number(workshop.page) < Number(workshop.totalPages) ? button(t('Next page'), 'workshopPage', { workshopPage: Number(workshop.page) + 1 }, { icon: 'chevronRight' }) : '') + (filtersCollapsed() ? button(t('Show filters'), 'toggleFilters') : ''),
  };
  if (discover && workshopSource().key === 'subscriptions') return {
    description: t('Wallpapers you subscribe to on the Steam Workshop appear here.'),
    actions: button(t('Browse Workshop'), 'workshopSource', { source: 'browse' }, { className: 'primary' }),
  };
  return { description: t('The Workshop returned no results.'), actions: button(t('Refresh Workshop'), 'refreshWorkshop', {}, { icon: 'refresh' }) };
}
// A tile's still. Discover shows the Workshop thumbnail; Installed shows the cover the native cache
// keeps for the preview file (libraryStill), so a GIF preview is not decoded at full size for a tile.
function tileStillMarkup(item, discover) {
  const still = discover ? { source: safeImage(item.thumbnail || item.preview), key: item.thumbnail || item.preview, fallback: '' } : libraryStill(item);
  if (!still.source) return '';
  return `<img ${keyAttr(still.key)} class="tile-still" src="${escapeHTML(still.source)}" alt=""${discover ? '' : ' loading="lazy"'} decoding="async"${still.source.startsWith('mwe-ui:') ? ' crossorigin="anonymous"' : ''}${still.fallback ? ` data-fallback="${escapeHTML(still.fallback)}"` : ''} referrerpolicy="no-referrer">`;
}
// Covers the native cache could not make, by cover address. The preview file itself stands in for
// them once; a cover address carries a stamp of the preview file, so they retry when it is replaced.
const brokenCovers = new Set();
function libraryStill(item) {
  const cover = safeImage(item.thumbnail), file = safeImage(item.preview);
  // The stamp is still being read: show nothing yet, never the full-size preview the cover stands for.
  if (!cover && item.coverPending) return { source: '', key: item.preview, fallback: '' };
  if (!cover) return { source: file, key: item.preview, fallback: '' };
  if (brokenCovers.has(cover) && file) return { source: file, key: item.preview, fallback: '' };
  return { source: cover, key: item.thumbnail, fallback: file };
}
function renderGrid(discover) {
  const workshop = state.workshop;
  const items = discover ? workshop.items || [] : visibleWallpapers();
  const loading = discover ? workshop.loading : state.libraryLoading;
  const selectedID = discover ? workshop.selectedID : state.selectedID;
  const target = state.displays.find(display => display.id === state.targetDisplayID);
  $('wallpaper-grid').setAttribute('aria-busy', String(Boolean(loading)));
  const count = t(items.length === 1 ? '{count} wallpaper' : '{count} wallpapers', { count: items.length.toLocaleString() });
  // Drag-selecting is taught where selecting happens: until the user has swept once or said
  // "Got it", every selection context carries the tip; afterwards a short reminder remains in
  // selection mode only.
  const updateCount = Number(state.workshopUpdates?.count) || 0;
  const updateAll = !discover && updateCount ? button(updateCount === 1 ? t('Update 1 wallpaper') : t('Update {count} wallpapers', { count: updateCount.toLocaleString() }), 'workshopUpdateAll', {}, { icon: 'download', className: 'link', title: t('Download the new versions the Workshop has of your wallpapers'), disabled: busy('workshopUpdateAll') }) : '';
  const sweepTip = !discover && items.length > 1 && !state.dragSelectLearned ? `<span class="selection-tip" role="note">${icon('mousePointerClick', 14)}<span>${escapeHTML(t('Tip: hold a tile, then drag across others to select them all at once.'))}</span>${button(t('Got it'), 'dragSelectLearned', {}, { className: 'link' })}</span>` : '';
  // The Steam page that lists what this panel page shows, for anything the panel does not offer.
  const steamPageLink = discover && workshop.loaded && workshop.steamURL ? button(t('Open on Steam'), 'openExternal', { url: workshop.steamURL }, { icon: 'external', className: 'link' }) : '';
  // Signed in, subscriptions say whose list it is, offer to download what the library lacks as
  // the list's main action, and the way to sign out again.
  const subscriptionBar = discover && workshopSource().key === 'subscriptions' && workshop.steamSignedIn ? `<div class="selection-bar subscription-bar"><span class="steam-session">${icon('circleCheck', 14)}<span>${escapeHTML(t('Signed in to Steam'))}</span></span>${workshop.loaded ? `<span>${escapeHTML(t('{count} subscribed', { count: Number(workshop.totalCount).toLocaleString() }))}</span>` : ''}${button(t('Download the ones not in your library'), 'workshopDownloadSubscribed', {}, { icon: 'download', className: 'primary', title: t('Downloads every wallpaper you subscribe to that isn’t in your library yet'), disabled: busy('workshopDownloadSubscribed') || (workshop.loaded && !Number(workshop.totalCount)) })}${button(t('Sign out of Steam'), 'steamWebSignOut', {}, { className: 'link', title: t('Forgets the Steam session this app read your subscriptions with') })}${steamPageLink}</div>` : '';
  morph($('browser-summary'), loading ? escapeHTML(discover ? t('Searching Steam Workshop…') : t('Loading your library…')) : subscriptionBar || (discover ? `<div class="selection-bar"><span>${escapeHTML(workshop.loaded && workshop.lookup ? t('Showing the item from your link. Filters don’t apply to it.') : workshop.loaded && workshop.degraded ? t('Steam changed its Workshop page, so this list may be incomplete.') : workshop.loaded ? t('{count} results', { count: Number(workshop.totalCount).toLocaleString() }) : t('Steam Workshop'))}</span>${steamPageLink}</div>` : selection.size ? `<div class="selection-bar"><span class="selection-count">${escapeHTML(t('{count} selected', { count: selection.size.toLocaleString() }))}</span>${button(t('Select all'), 'selectAllVisible', {}, { className: 'link', disabled: items.every(item => selection.has(item.id)) })}${button(t('Clear'), 'clearSelection', {}, { className: 'link' })}${button(selection.size === 1 ? t('Add to playlist') : t('Add {count} to playlist', { count: selection.size.toLocaleString() }), 'addSelectedToPlaylist', {}, { icon: 'listPlus', title: t('Adds them to the list of the target display’s playlist'), disabled: !target?.enabled || target.mode === 'mirror' || busy('playlistAdd') })}${collections.selectionTools()}${button(selection.size === 1 ? t('Move to Trash') : t('Move {count} to Trash', { count: selection.size.toLocaleString() }), 'deleteSelected', {}, { icon: 'trash', className: 'danger', disabled: state.busy || busy('deleteMany') })}${sweepTip}</div>` : `<div class="selection-bar"><span>${escapeHTML(count)}</span>${updateAll}${items.length && selecting ? `${sweepTip ? '' : `<span class="muted">${escapeHTML(t('Click or drag across tiles to select them.'))}</span>`}${button(t('Select all'), 'selectAllVisible', {}, { className: 'link' })}${sweepTip}` : ''}</div>`));
  $('wallpaper-grid').classList.toggle('selecting', !discover && (selecting || selection.size > 0));
  // Discover animates every tile on screen; Installed only the one under the pointer or keyboard
  // focus. An installed wallpaper keeps its Workshop id, so a live entry left over from Discover
  // would mark its Installed tile as playing and hide that tile's still: render() retires them.
  retireLivePreviews(new Set(discover ? items.map(item => item.id) : installedLiveKeep(items)));
  morph($('wallpaper-grid'), items.map(item => `<article class="wallpaper-tile${selection.has(item.id) ? ' checked' : ''}${!discover && sweepArmingID() === item.id ? ' arming' : ''}${live.get(item.id)?.playing ? ' playing' : ''}" ${keyAttr(item.id)}><button type="button" class="tile-select" data-action="${discover ? 'workshopSelect' : 'select'}" data-id="${escapeHTML(item.id)}" aria-pressed="${item.id === selectedID}" aria-label="${escapeHTML(item.title)}, ${escapeHTML(kindLabel(item))}${tileMarkNames(item, discover).map(name => `, ${escapeHTML(t(tileMarkGlyphs[name][1]))}`).join('')}${item.id === selectedID ? `, ${escapeHTML(t('selected'))}` : ''}"><span class="tile-placeholder">${icon('image', 28)}</span>${['loading', 'ready'].includes(live.get(item.id)?.status) ? `<img ${keyAttr(`live-${item.id}`)} class="tile-live" src="${escapeHTML(safeImage(item.animated))}" alt="" decoding="async" crossorigin="anonymous" referrerpolicy="no-referrer">` : ''}${tileStillMarkup(item, discover)}<span class="tile-caption"><span class="tile-title">${escapeHTML(item.title)}</span><span class="tile-kind">${escapeHTML(kindLabel(item))}</span></span></button>${tileMarksMarkup(item, discover)}${discover ? (item.collection ? '' : tileDownloadMarkup(item)) : tileApplyMarkup(item)}${!discover ? `<button type="button" class="tile-check" data-action="toggleSelect" data-id="${escapeHTML(item.id)}" aria-pressed="${selection.has(item.id)}" aria-label="${escapeHTML(selection.has(item.id) ? t('Deselect: {title}', { title: item.title }) : t('Select: {title}', { title: item.title }))}" title="${escapeHTML(t('Click to select, or drag from here across other tiles to select them too.'))}">${icon('check', 14)}</button><button type="button" class="tile-favorite" data-action="favorite" data-id="${escapeHTML(item.id)}" aria-pressed="${state.favorites.includes(item.id)}" aria-label="${escapeHTML(state.favorites.includes(item.id) ? t('Remove favorite: {title}', { title: item.title }) : t('Add favorite: {title}', { title: item.title }))}"${disabled(busy('favorite', { id: item.id }))}>${icon('heart', 14)}</button>${target?.wallpaperID === item.id ? `<span class="active-badge">${escapeHTML(t('Active'))}</span>` : item.active ? `<span class="active-badge">${escapeHTML(t('Other display'))}</span>` : ''}` : ''}</article>`).join(''));
  const empty = $('browser-empty'); empty.hidden = items.length > 0;
  $('wallpaper-grid').hidden = !items.length;
  const signInFirst = discover && workshopSource().key === 'subscriptions' && !workshop.steamSignedIn;
  if (!items.length && signInFirst && !loading) {
    morph(empty, `<h1>${escapeHTML(t('Sign in to see your subscriptions'))}</h1><p>${escapeHTML(t('Steam shows the wallpapers you subscribe to only to you. You sign in on Steam’s own page; WallpaperMachine keeps the session only until it quits, and uses it only to read this list.'))}</p><p>${escapeHTML(t('This is separate from the SteamCMD sign-in in Settings, which only downloads wallpapers.'))}</p><div class="actions">${workshop.steamSigningIn ? button(t('Show sign-in window'), 'steamWebSignIn', {}, { icon: 'logIn' }) : button(t('Sign in to Steam…'), 'steamWebSignIn', {}, { icon: 'logIn', className: 'primary' })}</div>`);
  } else if (!items.length) {
    const recovery = emptyRecovery(discover);
    morph(empty, loading ? `<h1>${escapeHTML(discover ? t('Loading Workshop') : t('Loading wallpapers'))}</h1><p>${escapeHTML(discover ? t('Fetching wallpapers from Steam.') : t('Reading your wallpaper library.'))}</p>` : workshop.error && discover ? `<h1>${escapeHTML(t('Workshop unavailable'))}</h1><p>${escapeHTML(workshop.error)}</p>${button(t('Try again'), 'workshopRetry', {}, { icon: 'refresh' })}` : `<h1>${escapeHTML(discover ? t('No wallpapers found') : state.wallpapers.length ? t('No matching wallpapers') : t('Your wallpaper library is empty'))}</h1><p>${escapeHTML(recovery.description)}</p><div class="actions">${recovery.actions}</div>`);
  }
  // Steam's public browse page stops at 1,000 pages of 30, whatever the result count says;
  // a page is exactly one of Steam's, so the panel never offers more than that.
  const pages = Math.min(workshopMaxPages(), Math.max(1, Number(workshop.totalPages) || 1));
  if (discover) queueLivePreviews();
  morph($('pagination'), discover ? `${workshop.error && items.length ? `<p class="error">${escapeHTML(workshop.error)}</p>${button(t('Retry'), 'workshopRetry')}` : ''}${button('', 'workshopPage', { workshopPage: Math.max(1, workshop.page - 1) }, { icon: 'chevronLeft', title: t('Previous page'), disabled: loading || workshop.page <= 1 })}<form class="page-jump" data-form="workshopPage" aria-label="${escapeHTML(t('Go to page'))}" novalidate><label>${escapeHTML(t('Page'))} <input type="number" name="page" ${keyAttr('workshop-page')} inputmode="numeric" min="1" max="${pages}" step="1" value="${workshop.page || 1}" title="${escapeHTML(t('Type a page number and press Return'))}" aria-label="${escapeHTML(t('Page number'))}"${disabled(loading || pages <= 1)}></label><span>${escapeHTML(t('of {pages}', { pages: pages.toLocaleString() }))}</span><button type="submit" class="link"${disabled(loading || pages <= 1)}>${escapeHTML(t('Go'))}</button></form>${button('', 'workshopPage', { workshopPage: workshop.page + 1 }, { icon: 'chevronRight', title: t('Next page'), disabled: loading || workshop.page >= pages })}` : '');
}
// The marks a tile wears in its top-left corner, the way Wallpaper Engine flags its own tiles:
// a check on Discover once the wallpaper is in the library, the green trophy for a wallpaper
// Wallpaper Engine staff approved, and a heart for one of the user's favorites. Approval comes
// from Steam's tag on Discover and from project.json in the library; favorites are the user's
// own list, so a Discover tile shows the heart too once its wallpaper is installed and loved.
const tileMarkGlyphs = { installed: ['check', 'In your library'], approved: ['trophy', 'Approved by Wallpaper Engine'], favorite: ['heart', 'Favorite'], update: ['download', 'Update available'] };
function tileMarkNames(item, discover) {
  const names = [];
  if (discover && state.wallpapers.some(wallpaper => wallpaper.id === item.id)) names.push('installed');
  if (item.approved) names.push('approved');
  if (state.favorites.includes(item.id)) names.push('favorite');
  if (!discover && item.updateAvailable) names.push('update');
  return names;
}
function tileMarksMarkup(item, discover) {
  const names = tileMarkNames(item, discover);
  return names.length ? `<span class="tile-marks">${names.map(name => `<span class="tile-mark ${name}" title="${escapeHTML(t(tileMarkGlyphs[name][1]))}">${icon(tileMarkGlyphs[name][0], 12)}</span>`).join('')}</span>` : '';
}
// A Discover tile wears its download state as a ring over the still, the way Wallpaper Engine's
// own library does: live progress while transferring, one click to cancel, a shield when Steam
// needs the user, and a retry mark after a failure. Once the wallpaper is in the library the
// tile's corner marks carry the check instead.
function tileDownloadMarkup(item) {
  const request = requestByID(item.id);
  const job = jobByID(item.id);
  if (request) return tileRing({ kind: request.paused ? 'queued' : 'attention', glyph: request.paused ? 'play' : 'shield', action: request.paused ? 'downloadResume' : 'continueSetup', id: item.id, label: request.paused ? t('Resume download') : t('Continue setup to download {title}', { title: item.title }) });
  if (job?.pending) {
    if (job.queued) return tileRing({ kind: 'queued', glyph: 'download', hoverGlyph: 'close', action: 'downloadCancel', id: item.id, label: t('{title} is waiting to download. Click to remove it from the queue', { title: item.title }) });
    if (job.prompt || job.challenge) return tileRing({ kind: 'attention', glyph: 'shield', action: 'continueSetup', id: item.id, label: t('Finish the Steam sign-in to download {title}', { title: item.title }) });
    const percent = Number.isFinite(job.progress) ? Math.round(clamp(job.progress) * 100) : null;
    const pace = speed(job.bytesPerSecond);
    const phase = phaseWord(job.phase);
    const progressText = percent === null ? job.status || t('Downloading') : t('Downloading {percent}%', { percent });
    // Bytes only move once Steam has been contacted, signed in and asked for the item. Until then
    // the ring sweeps and the phase word inside names that step, so the wait never reads as a stall;
    // a transfer that is measuring but has no percentage yet shows its speed instead. After the
    // last byte, "Finishing" replaces a frozen 100% while the files are validated and imported.
    const finishing = job.phase === 'finishing' && percent === 100;
    const word = finishing ? phase : percent === null && (job.phase !== 'transferring' || !pace) ? phase : '';
    return tileRing({ kind: percent === null ? 'busy' : 'progress', progress: percent === null ? null : clamp(job.progress), text: word || (percent === null ? '' : `${percent}%`), word: !!word, speed: pace, phase: job.phase, hoverGlyph: 'close', action: 'downloadCancel', id: item.id, label: t('{progress}: {title}. Click to cancel', { progress: pace ? t('{progress} at {speed}', { progress: progressText, speed: pace }) : progressText, title: item.title }) });
  }
  if (job?.paused) return tileRing({ kind: 'queued', glyph: 'play', action: 'downloadResume', id: item.id, label: t('Resume download') });
  if (job && needsReview(job)) return tileRing({ kind: 'failed', glyph: 'refresh', action: 'downloadRetry', id: item.id, label: t('{error} Click to try again', { error: job.error || t('Download cancelled.') }), disabled: !state.setup?.ready });
  return '';
}
// An installed tile shows the switch it waits on: a sweep while it is being applied and a quiet
// mark while queued behind another. Waiting is progress, not an error, and never blocks the tile.
function tileApplyMarkup(item) {
  if (item.id === state.applyingID) return tileRing({ kind: 'busy', text: t('Applying'), word: true, status: true, id: item.id, label: t('Applying {title}', { title: item.title }) });
  if ((state.queuedApplyIDs || []).includes(item.id)) return tileRing({ kind: 'queued', glyph: 'play', status: true, id: item.id, label: t('{title} is waiting to be applied', { title: item.title }) });
  return '';
}
// pathLength="100" makes the dash offset a percentage, and the busy sweep travels by dash offset rather
// than a rotate() transform: rotating a layer whose centre lands between pixels shimmers in WebKit.
function tileRing({ kind, glyph = '', hoverGlyph = '', progress = null, text = '', word = false, speed: pace = '', phase = '', action, id, label, disabled: off = false, status = false }) {
  const dashOffset = kind === 'busy' ? 100 : progress === null ? 0 : 100 * (1 - progress);
  const value = kind === 'progress' || kind === 'busy' ? `<circle class="ring-value" cx="36" cy="36" r="32" pathLength="100" stroke-dasharray="${kind === 'busy' ? '26 74' : '100'}" stroke-dashoffset="${dashOffset.toFixed(1)}" transform="rotate(-90 36 36)"/>` : '';
  const copy = text || pace ? `<span class="ring-copy"><span class="ring-label${word ? ' ring-phase' : ''}">${escapeHTML(text)}</span>${pace ? `<span class="ring-speed">${escapeHTML(pace)}</span>` : ''}</span>` : `<span class="ring-label">${glyph ? icon(glyph, 18) : ''}</span>`;
  const inner = `<svg class="ring" viewBox="0 0 72 72" aria-hidden="true"><circle class="ring-track" cx="36" cy="36" r="32"/>${value}</svg>${copy}${hoverGlyph ? `<span class="ring-hover">${icon(hoverGlyph, 18)}</span>` : ''}`;
  // A status ring reports progress the user cannot act on; clicks fall through to the tile.
  if (status) return `<span class="tile-download tile-status ${kind}" role="status" aria-label="${escapeHTML(label)}" title="${escapeHTML(label)}">${inner}</span>`;
  return `<button type="button" class="tile-download ${kind}" data-action="${action}" data-id="${escapeHTML(id)}"${phase ? ` data-phase="${escapeHTML(phase)}"` : ''} aria-label="${escapeHTML(label)}" title="${escapeHTML(label)}"${disabled(off)}>${inner}</button>`;
}
// One short word per SteamCMD step, sized to sit inside the ring; the full sentence stays in the
// tooltip, the inspector and the downloads list.
const phaseWords = { preparing: 'Preparing', connecting: 'Connecting', updating: 'Updating', signingIn: 'Signing in', requesting: 'Requesting', transferring: 'Downloading', finishing: 'Finishing' };
const phaseWord = (phase) => phaseWords[phase] ? t(phaseWords[phase]) : '';
// A Discover collection is named as one; everything else by its wallpaper type.
const kindLabel = (item) => item.collection ? t('Collection') : t(item.kind);
// Double-clicking a Discover tile downloads it; once it is in the library the same gesture applies it.
// A collection is opened instead.
function tileDoubleClickAction(id) {
  if (state.workshop.items.find(item => item.id === id)?.collection) return 'workshopCollection';
  if (state.wallpapers.some(item => item.id === id)) {
    const target = state.displays.find(display => display.id === state.targetDisplayID);
    const kind = state.wallpapers.find(item => item.id === id)?.kind;
    return !['Application', 'Unknown'].includes(kind) && target?.enabled && target.mode !== 'mirror' ? 'activate' : 'workshopSelect';
  }
  if (jobByID(id)?.pending) return 'workshopSelect';
  return requestByID(id) ? 'continueSetup' : 'requestDownload';
}

// GitHub's new-issue form, pre-filled with the wallpaper, the app version and what this panel knows
// about it: the failure the user just saw and the backend drawing it, fallback reason included. Nothing
// is sent from here: the browser opens the draft and the user decides whether to submit it.
function issueLink(item, failure = '') {
  const repository = safeLink(state.repositoryURL);
  if (!repository) return '';
  const url = new URL(`${repository.replace(/\/$/, '')}/issues/new`);
  const workshop = /^\d+$/.test(item.id) ? `https://steamcommunity.com/sharedfiles/filedetails/?id=${item.id}` : item.id;
  const renderers = [...new Set([...(state.settings?.sceneRenderers || []), ...(state.settings?.videoBackends || [])]
    .filter(report => report.wallpaperId === item.id && report.backend)
    .map(report => `${report.backend}${report.fallbackReason ? ` (fallback: ${report.fallbackReason})` : ''}`))];
  const facts = [`**Wallpaper:** ${item.title}`, `**Workshop item:** ${workshop}`, `**Type:** ${item.kind}`, `**App version:** ${state.version || 'unknown'}`];
  if (renderers.length) facts.push(`**Renderer:** ${renderers.join('; ')}`);
  if (failure) facts.push(`**Error:** ${failure}`);
  url.searchParams.set('title', `[${item.kind}] ${item.title}`);
  url.searchParams.set('body', [...facts, '', '**What went wrong?**', '', ''].join('\n'));
  return url.href;
}

// The background recorder's rating, with the conditions it was measured under: a rating
// taken on two displays with no limit says little about one display at 30 fps. Native
// sends the battery share only on a Mac with a battery.
function energyRating(energy) {
  const level = energyLevelLabel(energy?.level);
  if (!level || !Number.isFinite(Number(energy.milliwatts))) return '';
  const displays = Number(energy.displays) === 1 ? t('1 display') : t('{count} displays', { count: Number(energy.displays) || 0 });
  const rate = energy.frameRateCap != null && Number.isFinite(Number(energy.frameRateCap)) ? t('{fps} fps', { fps: Number(energy.frameRateCap) }) : t('each display’s own frame rate');
  const scale = `${Math.round(Number(energy.renderScale) * 100)}%`;
  const values = { level, power: milliwatts(energy.milliwatts), displays, rate, scale };
  const battery = batteryShare(energy.batteryPercentPerHour);
  if (battery) return t('{level}, about {power}. {battery} Measured while it played alone on {displays} at {rate}, {scale} render scale, with this window closed.', { ...values, battery });
  return t('{level}, about {power}. Measured while it played alone on {displays} at {rate}, {scale} render scale, with this window closed.', values);
}

// The author's other wallpapers, unless they are what is on show already.
function moreByAuthor(item) {
  const source = workshopSource();
  if (!/^\d{17}$/.test(item.creatorID || '') || (source.key === 'creator' && source.id === item.creatorID)) return '';
  return button(t('More by this author'), 'workshopCreator', { id: item.creatorID, name: item.creator }, { className: 'link inspector-author' });
}
// An installed Workshop wallpaper (its id is the Workshop's number) can be downloaded again to repair
// or refresh it, unless it cannot run on macOS or a download for it is under way or waiting for setup.
function canReinstall(item) {
  return /^\d+$/.test(item.id) && item.kind !== 'Application'
    && !state.downloads.some(download => download.id === item.id && download.pending) && !requestByID(item.id);
}
function renderInspector(discover) {
  const item = discover ? state.workshop.items.find(item => item.id === state.workshop.selectedID) : state.wallpapers.find(item => item.id === state.selectedID);
  if (!item) { morph($('inspector'), `<div class="inspector-empty"><h2>${escapeHTML(t('Select a wallpaper'))}</h2><p>${escapeHTML(t('Preview, details and options appear here.'))}</p></div>`); return; }
  const isInstalled = state.wallpapers.some(wallpaper => wallpaper.id === item.id);
  const target = state.displays.find(display => display.id === state.targetDisplayID);
  const canActivate = isInstalled && !['Application', 'Unknown'].includes(item.kind) && target?.enabled && target.mode !== 'mirror';
  const download = state.downloads.find(download => download.id === item.id);
  const request = requestByID(item.id);
  const percent = Number.isFinite(download?.progress) ? Math.round(clamp(download.progress) * 100) : null;
  // Download and apply needs a wallpaper that can run and a target display that can show one of its own.
  // Why a downloaded wallpaper was not applied is moot once the target display shows it.
  const applyNote = target?.wallpaperID === item.id ? '' : state.applyNotes?.[item.id] || '';
  const canDownloadAndApply = discover && !item.collection && item.kind !== 'Application' && target?.enabled && target.mode !== 'mirror';
  const downloadAction = discover && item.collection
    ? button(t('Open collection'), 'workshopCollection', { id: item.id, title: item.title }, { icon: 'layers', className: 'primary' })
    : request
    ? button(request.paused ? t('Resume download') : t('Continue setup'), request.paused ? 'downloadResume' : 'continueSetup', { id: request.id }, { icon: request.paused ? 'play' : 'shield', className: 'primary' })
    : download?.paused && !download.pending
      ? button(t('Resume download'), 'downloadResume', { id: item.id }, { icon: 'play', className: 'primary' })
    : download?.pending
      ? `${download.prompt || download.challenge ? button(t('Finish sign-in'), 'continueSetup', { id: item.id }, { icon: 'shield', className: 'primary' }) : button(download.queued ? t('Waiting to download') : percent === null ? t('Downloading') : t('Downloading {percent}%', { percent }), 'openDownloads', {}, { icon: 'download', className: 'primary' })}${button(download.queued ? t('Remove from queue') : t('Cancel'), 'downloadCancel', { id: item.id }, { className: 'quiet' })}`
      : `${button(download?.error ? t('Download again') : t('Download'), 'requestDownload', { id: item.id }, { icon: 'download', className: 'primary' })}${canDownloadAndApply ? button(t('Download and apply'), 'requestDownloadAndApply', { id: item.id }, { icon: 'play', className: 'wide inspector-apply-download' }) : ''}`;
  const options = !discover && state.options?.id === item.id ? state.options : null;
  // An illustration saved from the pixiv tab is a web wallpaper only in how it is shown; its id names the artwork.
  const pixivArtwork = !discover && /^pixiv-(\d+)-p\d+$/.exec(item.id)?.[1];
  const compatibility = discover && item.collection ? t('A collection is a list of Workshop items put together by its author. Open it to see and download them.') : pixivArtwork ? t('A still illustration saved from pixiv. Choose how it fits the screen under Image fit.') : !discover && item.id.startsWith('image-') ? t('A still image imported from your Mac. Choose how it fits the screen under Image fit.') : { Scene: t('Scene renderer is experimental.'), Video: t('Playback depends on the video codec.'), Web: t('Runs in a built-in web view. Mouse input and audio response reach the page; keyboard input does not.'), Application: t('Application wallpapers cannot run on macOS.'), Unknown: t('This wallpaper type is not supported.') }[item.kind] || '';
  const artworkLink = pixivArtwork ? button(t('View on pixiv'), 'openExternal', { url: `https://www.pixiv.net/artworks/${pixivArtwork}` }, { icon: 'external', className: 'link inspector-artwork-link' }) : '';
  const meta = [kindLabel(item), item.collection && item.collectionSize ? t(item.collectionSize === 1 ? '1 item' : '{count} items', { count: item.collectionSize.toLocaleString() }) : bytes(item.size), discover && Number.isFinite(item.subscriptions) ? t('{count} subscribers', { count: item.subscriptions.toLocaleString() }) : ''].filter(Boolean).map(escapeHTML).join('<span aria-hidden="true"> · </span>');
  const energy = !discover ? energyRating(item.energy) : '';
  // A failure this panel saw for the wallpaper (its download, or the last attempt to apply it) is
  // shown with a report prefilled with it; otherwise an installed wallpaper that can run offers a
  // plain report link beneath its compatibility note, where someone checking a problem is reading.
  const failure = (!isInstalled && download?.error && !download.pending ? download.error : '') || (isInstalled ? activationFailures.get(item.id) || '' : '');
  const failureReport = failure ? issueLink(item, failure) : '';
  const failureNotice = failure ? `<div class="notice error inspector-failure"><p>${escapeHTML(failure)}</p>${failureReport ? button(t('Report this problem on GitHub'), 'openExternal', { url: failureReport }, { icon: 'github', className: 'link' }) : ''}</div>` : '';
  const report = !failure && isInstalled && item.kind !== 'Application' ? issueLink(item) : '';
  const reportLink = report ? button(t('Not working? Report on GitHub'), 'openExternal', { url: report }, { icon: 'github', className: 'link inspector-report' }) : '';
  // The list button adds to or removes from the target display's own playlist list.
  const playlistIDs = state.playlists?.[state.targetDisplayID]?.wallpaperIDs || [];
  const inPlaylist = playlistIDs.includes(item.id);
  const playlistToggle = !discover && isInstalled && item.supported !== false ? button('', inPlaylist ? 'playlistRemove' : 'playlistAdd', { id: item.id }, { icon: inPlaylist ? 'listMinus' : 'listPlus', title: inPlaylist ? t('Remove from this display’s playlist') : t('Add to this display’s playlist'), className: `icon-button${inPlaylist ? ' playlist-selected' : ''}`, disabled: !target?.enabled || target.mode === 'mirror' }) : '';
  // One step for every display, offered only where there is more than one display to put it on.
  // A mirror follows its source and a disabled display shows nothing, so neither counts.
  const sharedDisplays = state.displays.filter(display => display.enabled && display.mode !== 'mirror');
  const applyAll = isInstalled && !discover && item.supported !== false && !['Application', 'Unknown'].includes(item.kind) && sharedDisplays.length >= 2
    ? button(t('Apply to all displays'), 'activateAll', { id: item.id }, { icon: 'monitor', className: 'wide inspector-apply-all', disabled: sharedDisplays.every(display => display.wallpaperID === item.id) }) : '';
  const secondary = `${applyAll}${discover ? button(t('View on Steam Workshop'), 'openExternal', { url: `https://steamcommunity.com/sharedfiles/filedetails/?id=${encodeURIComponent(item.id)}` }, { icon: 'external', className: 'wide', title: t('View on Steam Workshop') }) : isInstalled ? button(t('Show in Finder'), 'reveal', { id: item.id }, { icon: 'folder', className: 'wide', title: t('Show in Finder') }) : ''}${!discover && isInstalled ? button('', 'favorite', { id: item.id }, { icon: 'heart', title: state.favorites.includes(item.id) ? t('Remove from favorites') : t('Add to favorites'), className: `icon-button${state.favorites.includes(item.id) ? ' favorite-selected' : ''}` }) : ''}${/^\d+$/.test(item.id) ? button('', 'shareWallpaper', { id: item.id }, { icon: 'share', className: 'icon-button', title: t('Share…') }) : ''}${playlistToggle}${!discover && isInstalled && canReinstall(item) ? button('', 'workshopReinstall', { id: item.id }, { icon: 'refresh', className: 'icon-button', title: t('Reinstall from Workshop…') }) : ''}${!discover && isInstalled ? button('', 'delete', { id: item.id }, { icon: 'trash', className: 'icon-button danger', title: t('Move wallpaper to Trash') }) : ''}`;
  // An installed Workshop wallpaper whose author has changed it since: one click downloads the
  // new version, which replaces this one once it has arrived whole.
  const updating = isInstalled && download?.pending;
  const updateNotice = !discover && isInstalled && (item.updateAvailable || updating) ? `<div class="notice inspector-update" role="status"><p>${escapeHTML(updating ? (download.queued ? t('The update is waiting to download.') : percent === null ? t('Downloading the update…') : t('Downloading the update… {percent}%', { percent })) : Number.isFinite(item.updatedAt) ? t('Its author updated it on the Workshop on {date}.', { date: new Date(item.updatedAt).toLocaleDateString(language()) }) : t('Its author updated it on the Workshop.'))}</p><div class="actions">${updating ? button(t('Show in downloads'), 'openDownloads', {}, { className: 'link' }) : request ? button(t('Continue setup'), 'continueSetup', { id: request.id }, { icon: 'shield', className: 'primary' }) : button(t('Update'), 'workshopUpdate', { id: item.id }, { icon: 'download', className: 'primary', disabled: busy('workshopUpdate', { id: item.id }) })}</div></div>` : '';
  const showInLibrary = discover && isInstalled && !(download && !download.pending && !download.error) ? button(t('Show in library'), 'showInstalled', { id: item.id }, { icon: 'image', className: 'link' }) : '';
  // Applying what the display already shows does nothing, so that button restarts it instead.
  const reapplies = target?.wallpaperID === item.id;
  const activateLabel = reapplies ? t('Reapply wallpaper') : t('Apply wallpaper');
  const activation = isInstalled ? button('', reapplies ? 'reapplyWallpaper' : 'activate', { id: item.id }, { icon: 'play', title: activateLabel, className: 'primary inspector-play', disabled: !canActivate }) : '';
  const previewAction = isInstalled && state.previewAvailable && !['Application', 'Unknown'].includes(item.kind)
    ? button(t('Preview wallpaper'), 'previewWallpaper', { id: item.id }, { icon: 'eye', className: 'wide', title: t('Open a live preview without changing your desktop') }) : '';
  morph($('inspector'), `<div class="inspector-layout" ${keyAttr(`inspector-${item.id}-${discover}`)}><div class="inspector-scroll"><div class="inspector-heading">
    <div class="inspector-artwork"><div class="inspector-preview">${preview(item.preview)}</div>${activation}</div>
    <h2>${escapeHTML(item.title)}</h2>${discover && item.creator ? `<p class="inspector-creator">${escapeHTML(item.creator)}${moreByAuthor(item)}</p>` : ''}
    <p class="inspector-meta">${meta}</p>${energy ? `<p class="inspector-energy muted"><small>${escapeHTML(energy)}</small></p>` : ''}
    <div class="actions inspector-actions">${!isInstalled ? downloadAction : ''}${previewAction}${secondary}</div>${tags(item.tags)}
    ${!isInstalled && download?.pending && !download.queued ? `<progress class="inspector-progress" max="1"${Number.isFinite(download.progress) ? ` value="${clamp(download.progress)}"` : ''} aria-label="${escapeHTML(t('{title} download progress', { title: item.title }))}"></progress><p class="muted"><small>${escapeHTML(download.status)}${transfer(download, { includePercent: false }) ? ` · ${transfer(download, { includePercent: false })}` : ''}</small></p>` : ''}
    ${request ? `<p class="muted"><small>${escapeHTML(stageHint(request.stage))}</small></p>` : ''}
    ${(request || download?.pending) && (request || download).applyOnArrival ? `<p class="muted inspector-apply-intent"><small>${escapeHTML(t('Will apply when the download finishes.'))}</small></p>` : ''}
    ${applyNote ? `<div class="notice inspector-apply-note" role="status"><p>${escapeHTML(applyNote)}</p></div>` : ''}
    ${updateNotice}
    ${failureNotice}
    ${!discover ? hostStatusMarkup(item.id) : ''}
    ${isInstalled && download && !download.pending && !download.error ? button(t('Show in library'), 'showInstalled', { id: item.id }, { icon: 'image', className: 'link' }) : ''}
    ${download || request ? button(t('Show in downloads'), 'openDownloads', {}, { className: 'link' }) : ''}
    ${compatibility ? `<p class="inspector-compatibility muted"><small>${escapeHTML(compatibility)}</small></p>` : ''}${artworkLink}${reportLink}
    ${item.kind === 'Scene' && !state.settings.sceneAssetsReady ? `<div class="notice warning">${escapeHTML(t('Shared scene resources are required before playback.'))} ${button(t('Get shared resources'), 'requestAssets', {}, { className: 'link' })}</div>` : ''}${showInLibrary}
    </div>${discover ? (item.summary ? `<section class="inspector-section"><p>${escapeHTML(item.summary)}</p></section>` : '') : `${isInstalled ? compatibilityCard.section(item, target) : ''}${isInstalled && item.kind === 'Video' ? letterbox.section(item, target) : ''}${isInstalled && packagedStill(item.id) ? placement.section(item) : ''}${options ? renderOptions(options, isInstalled ? collections.inspectorSection(item) : '') : `<section class="inspector-section"><p class="muted">${escapeHTML(t('Loading wallpaper options…'))}</p></section>${isInstalled ? collections.inspectorSection(item) : ''}`}`}
    </div>${options ? renderInspectorSave(options) : ''}</div>`);
  for (const image of $('inspector').querySelectorAll('img[data-label-height]')) image.style.height = `${Number(image.dataset.labelHeight)}px`;
  placement.layout();
}
const draftKey = (id, propertyID) => `${id}\u0000${propertyID}`;
function hostStatusMarkup(id) {
  return (state.hostStates || []).filter(row => row.wallpaperID === id).map(row => {
    const label = row.phase === 'failed' ? t('Wallpaper could not load')
      : row.phase === 'ready' ? t('Wallpaper content is ready') : t('Loading wallpaper content…');
    return `<div class="notice ${row.phase === 'failed' ? 'error' : 'muted'}" data-host-display="${escapeHTML(row.displayID)}" role="status"><strong>${escapeHTML(row.displayTitle)} · ${escapeHTML(label)}</strong>${row.message ? `<p>${escapeHTML(row.message)}</p>` : ''}${row.canRetry ? button(t('Retry wallpaper'), 'retryHostWallpaper', { id, displayID: row.displayID }, { className: 'link', icon: 'refresh', disabled: busy('retryHostWallpaper', { id, displayID: row.displayID }) }) : ''}</div>`;
  }).join('');
}
// Delivery is reported by the native host for this wallpaper. A setting or a
// subscription alone is never presented as a received audio frame.
function renderAudioAndMedia(options, lock) {
  const id = options.id;
  const web = options.kind === 'Web';
  const check = (key, label, on) => `<label class="check-label inspector-check">${icon(key === 'audioResponseEnabled' ? 'audioLines' : 'music')}<span>${escapeHTML(label)}</span><input type="checkbox" data-change="wallpaperSetting" data-id="${escapeHTML(id)}" data-setting="${escapeHTML(key)}"${checked(on)}${disabled(lock)}></label>`;
  const note = (text) => `<p class="muted"><small>${escapeHTML(text)}</small></p>`;
  const status = (text) => `<p class="muted" role="status"><small>${escapeHTML(text)}</small></p>`;
  // Three distinct things: the user's setting, whether the page asked for data,
  // and whether anything can answer. Never collapse them into one sentence.
  const delivering = options.audioDelivering;
  const audioStatus = !options.audioResponseEnabled
    ? t('Off. No audio is captured.')
    : !web
      ? t('On. Parts of the wallpaper made to react to sound will respond.')
      : delivering === true
        ? t('On. The wallpaper is receiving audio.')
        : options.audioDeliveryState === 'subscribed'
          ? t('On. Waiting for an audio frame.')
        : options.audioDeliveryState === 'connecting'
          ? t('On. Connecting to audio…')
        : options.audioDeliveryState === 'failed'
          ? t('Audio could not be connected. Turn Audio response off and on to retry.')
        : delivering === false
          ? t('On, but this wallpaper doesn’t use audio.')
          : t('On. Apply the wallpaper to see whether it uses audio.');
  const media = !(web || options.kind === 'Scene') ? '' : check('mediaIntegrationEnabled', t('Media integration'), options.mediaIntegrationEnabled);
  const mediaStatus = !options.mediaIntegrationEnabled
    ? t('Off. The wallpaper gets no track information.')
    : options.mediaAvailable === true
      ? t('On. The wallpaper gets the track details macOS reports.')
      : options.mediaAvailable === false
        ? t('On, but track information is unavailable: {reason}', { reason: options.mediaUnavailableReason || t('the system declined to report what is playing.') })
        : t('On. Apply the wallpaper to see whether track information is available.');
  // How a web page's own sound is controlled: native sets the volume of the page's audio and
  // video elements and can mute the page as a whole, but promises nothing about the level of
  // sound made with Web Audio, which only whole-page mute reaches. Each is reported only as
  // native has observed it; before the page runs, both are unknown.
  const control = web && options.webAudioControl && typeof options.webAudioControl === 'object' ? options.webAudioControl : null;
  const volumeStatus = !control ? '' : control.volume === 'mediaElements'
    ? t('Volume sets the level of the audio and video the page plays through media elements. Sound the page makes with Web Audio does not follow it; only Mute does.')
    : control.volume === 'unavailable'
      ? t('Media volume cannot be changed for this page on this version of macOS.')
      : t('How far Volume reaches is confirmed once the wallpaper is running.');
  const muteStatus = !control ? '' : control.mute === 'available'
    ? t('Mute silences the whole page, including sound made with Web Audio.')
    : control.mute === 'unavailable'
      ? t('Whole-page mute is not available on this version of macOS, so this page cannot be muted reliably.')
      : t('Whether the whole page can be muted is confirmed once the wallpaper is running.');
  return check('audioResponseEnabled', t('Audio response'), options.audioResponseEnabled) + media
    + `<details class="inspector-help" ${keyAttr(`audio-help-${id}`)}><summary>${escapeHTML(t('Audio and media status'))}${icon('chevronRight', 12)}</summary><div class="section-content">`
    + note(t('Reactive wallpapers use sound playing in other apps. macOS may request system audio recording permission.'))
    + status(audioStatus)
    + (media ? note(t('Share song titles, artists and artwork from system Now Playing. Supports Spotify, Apple Music and compatible browsers and local players.')) + status(mediaStatus) : '')
    + (control ? note(t('Output controls are separate from system-audio response.')) + status(volumeStatus) + status(muteStatus) : '')
    + '</div></details>';
}
// Where a scene or video sits on one display: the room the display leaves around it (bars) or the
// overflow it crops is split by a fraction per axis. Native saves the position the moment a
// slider settles and the wallpaper follows without restarting, so unlike the scale factor beside it
// this is not a draft and Apply does not wait for it. The percentages are only for reading;
// native takes fractions. The sliders stay enabled while a command runs: their changes queue, and
// a disabled slider would drop the keyboard focus the next arrow key needs. A still image page is
// kind Web and keeps its own Position on screen, and a web wallpaper has nothing to move.
function positionRows(options, display, index) {
  if (!['Scene', 'Video'].includes(options.kind) || !options.supported) return '';
  const fraction = (value) => Number.isFinite(Number(value)) ? Math.min(1, Math.max(0, Number(value))) : 0.5;
  const x = fraction(display.panX), y = fraction(display.panY);
  const slider = (axis, label, value) => `<div class="field" ${keyAttr(`position-${axis}`)}><label for="position-${axis}-${index}">${escapeHTML(label)}</label><div class="range-field"><input id="position-${axis}-${index}" type="range" min="0" max="100" step="1" value="${Math.round(value * 100)}" data-change="displayPosition" data-axis="${axis}" data-id="${escapeHTML(options.id)}" data-display-id="${escapeHTML(display.id)}"><output>${Math.round(value * 100)}%</output></div></div>`;
  const note = display.nativePlayer
    ? `${escapeHTML(t('This video is drawn by the native video player, which keeps it centered. Choose Compatibility for Video playback in Performance settings to move it.'))} ${button(t('Open Performance'), 'openPerformance', {}, { className: 'link' })}`
    : escapeHTML(t('Choose which part of the wallpaper stays in view when it is larger than the display, or where it sits when it is smaller. Nothing moves when it already fits the display exactly.'));
  return `<div class="position-rows" ${keyAttr(`position-${display.id}`)}>${slider('x', t('Horizontal position'), x)}${slider('y', t('Vertical position'), y)}<div class="actions">${button(t('Center'), 'displayPositionReset', { id: options.id, displayID: display.id }, { className: 'link', icon: 'refresh', disabled: x === 0.5 && y === 0.5, title: t('Center the wallpaper on the display') })}</div><p class="muted field-note"><small>${note}</small></p></div>`;
}
// A Position slider also shows the wallpaper at the thumb while the person drags it, and a property's
// slider or colour picker does the same with its value. The page sends the newest value at most every
// PREVIEW_MS and one step at a time, native keeps nothing from it and does not reply with a snapshot,
// and a step that fails is ignored: the release sends the value that counts through `send`, which
// saves it and reports its own errors. Only a pointer drag previews (a key press or VoiceOver
// action fires its change at once), and the release waits for the step still on its way so that step
// cannot land after it. A drag that ends where it began fires no change, so the pointer coming up,
// being cancelled or leaving the window settles it with the value last shown; otherwise the
// wallpaper would stay at the last step.
//
// `describe(element)` gives the step an input event stands for, or nothing: its `value`, the
// `message` that shows a value, the `commit` that saves one, and `unpointed` for a control whose
// drag the page cannot see because it happens in a panel of its own (a colour picker). That one
// waits a task before its first step, so a single pick, whose change event follows at once, shows
// nothing before it is saved.
function dragPreview({ action, pointerOn, describe }) {
  const PREVIEW_MS = 100;
  let pointerDown = false, drag = null;
  function preview(message) {
    const bridge = window.webkit?.messageHandlers?.native;
    if (!bridge) return Promise.resolve();
    try { return Promise.resolve(bridge.postMessage({ action, ...message })).then(() => {}, () => {}); } catch { return Promise.resolve(); }
  }
  function pump(current) {
    if (drag !== current || current.inFlight || current.timer || current.value === current.shown) return;
    const wait = current.sentAt + PREVIEW_MS - performance.now();
    if (wait > 0) { current.timer = setTimeout(() => { current.timer = 0; pump(current); }, wait); return; }
    current.shown = current.value; current.sentAt = performance.now();
    current.inFlight = preview(current.message(current.value)).then(() => { current.inFlight = null; pump(current); });
  }
  // Ends the drag in progress. The promise settles once the step already sent has been answered.
  function end() {
    const current = drag; drag = null;
    if (!current) return Promise.resolve();
    clearTimeout(current.timer); current.timer = 0;
    return current.inFlight || Promise.resolve();
  }
  function settle() {
    if (drag) run(drag.commit(drag.value));
  }
  function release() { if (!pointerDown) return; pointerDown = false; setTimeout(settle, 0); }
  document.addEventListener('pointerdown', event => { pointerDown = Boolean(event.target.closest?.(pointerOn)); });
  for (const type of ['pointerup', 'pointercancel']) document.addEventListener(type, release);
  // The button came up outside the window, where no pointerup reached the page.
  document.addEventListener('pointermove', event => { if (pointerDown && !(event.buttons & 1)) release(); });
  window.addEventListener('blur', () => { pointerDown = false; settle(); });
  return {
    end,
    input(element) {
      const step = describe(element);
      if (!step || (!pointerDown && !step.unpointed)) return;
      if (drag?.element !== element) {
        clearTimeout(drag?.timer);
        drag = { element, shown: NaN, inFlight: null, timer: 0, sentAt: -Infinity };
        if (step.unpointed) drag.timer = setTimeout(() => { const current = drag; if (current?.element === element) { current.timer = 0; pump(current); } }, 0);
      }
      Object.assign(drag, { value: step.value, message: step.message, commit: step.commit });
      pump(drag);
    },
  };
}
const positionDrag = dragPreview({
  action: 'displayPositionPreview',
  pointerOn: 'input[data-change="displayPosition"]',
  describe(element) {
    const axis = element.dataset.axis;
    if (axis !== 'x' && axis !== 'y') return null;
    const { id, displayId: displayID } = element.dataset;
    return {
      value: Number(element.value) / 100,
      message: value => ({ id, displayID, [axis]: value }),
      commit: value => commitPosition(id, displayID, axis, value),
    };
  },
});
async function commitPosition(id, displayID, axis, fraction) {
  await positionDrag.end();
  return send('displayPosition', { id, displayID, [axis]: fraction });
}
const propertyDrag = dragPreview({
  action: 'propertyPreview',
  pointerOn: 'input[type="range"][data-change="property"]',
  describe(element) {
    if (element.type !== 'range' && element.type !== 'color') return null;
    const value = element.type === 'range' ? Number(element.value) : element.value;
    if (typeof value === 'number' && !Number.isFinite(value)) return null;
    const { id, propertyId } = element.dataset;
    return {
      value,
      unpointed: element.type === 'color',
      message: value => ({ id, propertyID: propertyId, value }),
      commit: value => commitPropertyValue(id, propertyId, value),
    };
  },
});
// Displays and collections sit above the properties, which can run very long; Displays
// opens by itself once the wallpaper is on a display.
function renderOptions(options, collectionsSection = '') {
  const id = options.id;
  const lock = state.busy || busy('apply', { id }) || busy('revert', { id });
  const properties = (options.properties || []).map(property => renderProperty(id, property, lock)).join('');
  // Presets count unsent page drafts as dirty too, as the Apply changes footer does.
  const unsent = [...drafts.keys()].some(key => key.startsWith(`${id}\u0000`));
  const dirty = Boolean(options.dirty) || unsent;
  // A chosen file or folder is saved as it is picked and keeps its own Clear, so only the rest can be restored.
  // A value behind a rule that hides its row can be too, though the page is not given the row.
  const restorable = unsent || Boolean(options.hiddenModified) || (options.properties || []).some(property => property.dirty && property.kind !== 'file' && property.kind !== 'directory');
  const restoreAll = button(t('Restore all defaults'), 'restoreAllProperties', { id }, { className: 'link', icon: 'refresh', title: t('Stages the default for every property except chosen files and folders. Revert undoes it.'), disabled: lock || !options.supported || !restorable });
  return `${!options.supported ? `<section class="inspector-section"><p class="notice warning">${escapeHTML(t('This wallpaper cannot be rendered on this Mac.'))}</p></section>` : ''}
    <section class="inspector-section"><details open ${keyAttr(`general-${id}`)}><summary>${escapeHTML(t('General configuration'))}${icon('chevronRight', 14)}</summary><div class="section-content general-controls">
      <label class="check-label inspector-check">${icon('volume')}<span>${escapeHTML(t('Mute wallpaper audio'))}</span><input type="checkbox" data-change="wallpaperSetting" data-id="${escapeHTML(id)}" data-setting="muted"${checked(options.muted)}${disabled(lock)}></label>
      <div class="field inspector-row"><label for="wallpaper-volume">${icon('volume')}${escapeHTML(t('Volume'))}</label><div class="range-field"><input id="wallpaper-volume" type="range" min="0" max="100" step="1" value="${Number(options.volume) * 100}" data-change="wallpaperSetting" data-id="${escapeHTML(id)}" data-setting="volume"${disabled(lock || options.muted)}><output>${Math.round(options.volume * 100)}%</output></div></div>
      ${renderAudioAndMedia(options, lock)}
    </div></details></section>
    <section class="inspector-section"><details${options.displays?.length ? ' open' : ''} ${keyAttr(`displays-${id}`)}><summary>${escapeHTML(t('Displays'))}${icon('chevronRight', 14)}</summary><div class="section-content">${(options.displays || []).map((display, index) => `<details class="display-options" open ${keyAttr(display.id)}><summary>${escapeHTML(display.title)}${icon('chevronRight', 13)}</summary><div class="section-content"><label class="check-label"><input type="checkbox" data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="enabled"${checked(display.enabled)}${disabled(lock)}>${escapeHTML(t('Enabled'))}</label><label class="field">${escapeHTML(t('Scaling mode'))}<select data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="scalingMode"${disabled(lock)}>${selectOptions([['none', t('Original size')], ['stretch', t('Stretch')], ['match', t('Fit')], ['fill', t('Fill')]], display.scalingMode)}</select></label><label class="field">${escapeHTML(t('Scale factor'))}<input type="number" min="${Number.MIN_VALUE}" step="any" value="${Number(display.scalingFactor)}" data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="scalingFactor"${disabled(lock)}></label><label class="field">${escapeHTML(t('Frame rate'))}<input type="number" min="1" max="${Number(display.maxFps) || 240}" step="1" value="${Number(display.fps)}" data-change="displayConfig" data-id="${escapeHTML(id)}" data-display-id="${escapeHTML(display.id)}" data-setting="fps"${disabled(lock)}></label>${(() => { const limited = performanceLimitedFps(display.fps, state.settings || {}); return limited == null ? '' : `<p class="muted field-note"><small>${escapeHTML(t('Limited to {fps} fps by Performance settings', { fps: limited }))}</small> ${button(t('Open Performance'), 'openPerformance', {}, { className: 'link' })}</p>`; })()}${positionRows(options, display, index)}${button(t('Remove from display'), 'eject', { id, displayID: display.id }, { className: 'link', disabled: lock })}</div></details>`).join('') || `<p class="muted">${escapeHTML(t('Apply this wallpaper to a display to configure playback.'))}</p>`}</div></details></section>${collectionsSection}
    ${properties ? `<section class="inspector-section"><details open ${keyAttr(`properties-${id}`)}><summary>${escapeHTML(t('Wallpaper properties'))}${icon('chevronRight', 14)}</summary><div class="section-content wallpaper-properties">${presets.section({ id }, { dirty })}<div class="property-tools" ${keyAttr(`property-tools-${id}`)}>${restoreAll}</div>${properties}</div></details></section>` : ''}`;
}
function renderInspectorSave(options) {
  const id = options.id;
  const lock = state.busy || busy('apply', { id }) || busy('revert', { id });
  const changed = options.dirty || [...drafts.keys()].some(key => key.startsWith(`${id}\u0000`));
  return `<div class="inspector-save"><p role="status">${escapeHTML(changed ? t('You have unapplied changes.') : t('Audio, scaling mode and frame rate update immediately.'))}</p>${button(t('Revert'), 'revert', { id }, { disabled: lock || !changed })}${button(t('Apply changes'), 'apply', { id }, { className: 'primary', disabled: lock || !changed || !options.supported })}</div>`;
}
// A `file` or `directory` property is a path the user picked, not a value typed into the
// page: the field is read-only and carries the display name, never the staged path the
// wallpaper actually reads. Every part of it — name, accepted types, staging failure —
// is attacker-influenced, so it goes through escapeHTML like everything else here.
function assetProperty(id, property, fieldID, unavailable, name) {
  const directory = property.kind === 'directory';
  const chosen = property.fileName || '';
  const empty = directory ? t('No folder chosen') : t('No file chosen');
  const types = (property.fileTypes || []).join(', ');
  const count = Number(property.fileCount);
  const limit = Number(property.fileLimit);
  const notes = [];
  // Both lines describe the folder, never an import outcome: a failed link or copy is
  // skipped and logged by the importer, so the staged count can be under the cap.
  if (types) notes.push(directory ? t('Uses {types} files from the chosen folder.', { types }) : t('Accepts {types}.', { types }));
  if (directory && chosen) {
    if (Number.isFinite(count)) {
      notes.push(property.truncated && Number.isFinite(limit)
        ? t('More than {limit} files match; only the first {limit} are used.', { limit })
        : t(count === 1 ? '{count} matching file in this folder.' : '{count} matching files in this folder.', { count }));
    } else {
      notes.push(t('This folder could not be read. Choose it again, or pick another.'));
    }
    notes.push(property.directoryMode === 'fetchAll'
      ? t('The wallpaper receives the whole list of files.')
      : t('The wallpaper picks files from the folder itself.'));
  }
  const missing = chosen && property.assetMissing === true;
  // Where the file lives now. A missing asset is the one state the user has to
  // act on, so it gets a visible alert and the picker, and the where-it-lives
  // note is dropped: telling someone an asset is safely copied and also gone
  // reads as a contradiction rather than as two facts.
  if (chosen && !missing && property.assetManaged === true) {
    notes.push(t('Copied into this app’s managed folder, so it survives cache cleans and wallpaper updates.'));
  } else if (chosen && !missing && property.assetManaged === false) {
    notes.push(property.assetSourcePath
      ? t('Used in place from {path}. Moving or deleting it there breaks the wallpaper.', { path: property.assetSourcePath })
      : t('Used in place from where you chose it. Moving or deleting it there breaks the wallpaper.'));
  }
  return `<input type="text" id="${escapeHTML(fieldID)}" class="asset-value" readonly value="${escapeHTML(chosen || empty)}">`
    + `<div class="actions">${button(missing ? t('Reselect…') : t('Choose…'), 'choosePropertyPath', { id, propertyID: property.id }, { icon: 'folder', title: directory ? t('Choose a folder for {name}', { name }) : t('Choose a file for {name}', { name }), disabled: unavailable })}`
    + `${button(t('Clear'), 'clearPropertyPath', { id, propertyID: property.id }, { title: t('Clear {name}', { name }), disabled: unavailable || !chosen })}</div>`
    + (missing ? `<p class="notice warning" role="alert">${escapeHTML(property.assetSourcePath ? (directory ? t('Missing — this folder is no longer at {path}. Reselect it.', { path: property.assetSourcePath }) : t('Missing — this file is no longer at {path}. Reselect it.', { path: property.assetSourcePath })) : (directory ? t('Missing — this folder can no longer be found. Reselect it.') : t('Missing — this file can no longer be found. Reselect it.')))}</p>` : '')
    + notes.map(note => `<p class="muted"><small>${escapeHTML(note)}</small></p>`).join('')
    + (property.error ? `<p class="notice error" role="alert">${escapeHTML(property.error)}</p>` : '');
}
function renderProperty(id, property, lock) {
  const token = String(property.labelHTML || property.label || '').trim();
  const engineLabel = Object.hasOwn(enginePropertyLabels, token) ? enginePropertyLabels[token]
    : packagedStill(id) && packagedPropertyLabels.includes(token) ? token
    // Any other built-in token arrives as words from the app; the same phrase in the catalog is translated.
    : engineToken.test(token) && property.label ? property.label : null;
  const presentation = engineLabel ? { ...property, label: t(engineLabel), labelHTML: '' } : property;
  const name = presentation.label || t('Unnamed option');
  const label = renderPropertyLabel(presentation);
  const fieldID = `property-${encodeURIComponent(id)}-${encodeURIComponent(property.id)}`;
  const value = drafts.has(draftKey(id, property.id)) ? drafts.get(draftKey(id, property.id)) : property.value;
  const modified = property.dirty || drafts.has(draftKey(id, property.id));
  const unavailable = lock || property.enabled === false || busy('property', { id, propertyID: property.id });
  const attributes = `id="${escapeHTML(fieldID)}" aria-label="${escapeHTML(name)}" data-change="property" data-id="${escapeHTML(id)}" data-property-id="${escapeHTML(property.id)}"${disabled(unavailable)}`;
  let control;
  switch (property.kind) {
    case 'boolean': control = `<input type="checkbox" ${attributes}${checked(value)}>`; break;
    case 'slider': control = `<div class="range-field"><input type="range" ${attributes} min="${Number(property.min ?? 0)}" max="${Number(property.max ?? 100)}" step="${Number(property.step) > 0 ? Number(property.step) : 'any'}" value="${Number(value)}"><output>${escapeHTML(value)}</output></div>`; break;
    case 'combo': control = `<select ${attributes}>${(property.options || []).map(option => `<option value="${escapeHTML(JSON.stringify(option.value))}"${JSON.stringify(value) === JSON.stringify(option.value) ? ' selected' : ''}>${escapeHTML(t(option.label))}</option>`).join('')}</select>`; break;
    case 'color': control = `<input type="color" ${attributes} value="${/^#[0-9a-f]{6}$/i.test(value) ? value : '#ffffff'}">`; break;
    case 'textInput': control = `<input type="text" ${attributes} data-input="property" value="${escapeHTML(value)}" autocomplete="off">`; break;
    // A scene texture is not a user-chosen file: it keeps the image picker it always had.
    case 'texture': control = `<p class="file-value">${escapeHTML(value || t('No image selected'))}</p><div class="actions">${button(t('Choose image'), 'choosePropertyFile', { id, propertyID: property.id }, { icon: 'folder', disabled: unavailable })}${value ? button(t('Clear'), 'clearProperty', { id, propertyID: property.id }, { disabled: unavailable }) : ''}</div>`; break;
    case 'file': case 'directory': control = assetProperty(id, property, fieldID, unavailable, name); break;
    case 'text': { const extra = value && value !== property.label ? `<p>${escapeHTML(value)}</p>` : ''; return label || extra ? `<div ${keyAttr(property.id)} class="property-description property-label">${label}${extra}</div>` : ''; }
    // A group only names the controls after it. A div with a heading role, not an <h3>, because an
    // author's own label may carry headings of its own and a heading cannot hold one.
    case 'group': return label ? `<div ${keyAttr(property.id)} class="property-group property-label" role="heading" aria-level="3">${label}</div>` : '';
    default: return `<p ${keyAttr(property.id)} class="muted">${escapeHTML(t('{name}: unsupported property type.', { name }))}</p>`;
  }
  const restore = property.defaultValue !== undefined && property.defaultValue !== null ? button('', 'restoreProperty', { id, propertyID: property.id }, { icon: 'refresh', className: 'quiet icon-button property-reset', title: t('Restore default: {name}', { name }), disabled: unavailable }) : '';
  return `<div ${keyAttr(property.id)} class="field property-row property-${escapeHTML(property.kind)}${modified ? ' modified' : ''}"><div class="field-title"><label class="property-label" for="${escapeHTML(fieldID)}">${label || escapeHTML(name)}</label>${modified ? `<span class="field-flag">${escapeHTML(t('Modified'))}</span>` : ''}</div><div class="property-control">${control}</div>${restore}</div>`;
}
// The property labels this app writes into the still images it packages, saved from pixiv or
// imported from disk. The manifest keeps them in English, as any wallpaper's are; being ours, they
// are translated for those wallpapers, which the library knows by their id.
const packagedPropertyLabels = ['Image fit', 'Background color'];
const packagedStill = (id) => /^(pixiv|image)-/.test(id);
// Wallpaper Engine's built-in label tokens are UI vocabulary, not author prose. A token with no
// phrase below is shown as the English words the app derives from it (at most 96 characters, as there).
const engineToken = /^ui_[A-Za-z0-9_]{1,93}$/;
const enginePropertyLabels = {
  ui_browse_properties_scheme_color: 'Scheme color',
  ui_editor_properties_alert_tip: 'Hint',
  ui_editor_effect_local_contrast_title: 'Local contrast',
  ui_editor_properties_brightness: 'Brightness',
  ui_editor_properties_default: 'Default',
  ui_editor_properties_left: 'Left',
  ui_editor_properties_right: 'Right',
  ui_editor_properties_position: 'Position',
  ui_editor_layer_solid: 'Solid color',
  ui_editor_properties_size: 'Size',
  ui_settings_enable_media_integration_support: 'Media integration',
  ui_editor_script_snippets: 'Script snippets',
  ui_editor_preset_stars_title: 'Stars',
  // Where the derived words are not the intended phrase.
  ui_editor_properties_pivot_offset_x: 'Pivot offset X',
  ui_editor_properties_pivot_offset_y: 'Pivot offset Y',
  ui_editor_properties_use_24h_format: 'Use 24-hour format',
};

const clamp = (value) => Math.max(0, Math.min(1, Number(value)));
const requestByID = (id) => (state?.downloadRequests || []).find(request => request.id === id);
const jobByID = (id) => (state?.downloads || []).find(item => item.id === id);
const stageHint = (stage) => t({ setup: 'Waiting for SteamCMD setup.', account: 'Waiting for your Steam sign-in.', resources: 'Waiting for your go-ahead on shared resources.', ready: 'Starting…' }[stage] || 'Waiting to continue.');
const stageTitle = (stage) => t({ setup: 'Install SteamCMD', account: 'Sign in to Steam', resources: 'Shared resources needed', ready: 'Starting download' }[stage] || 'Continue this download');
const strong = (text) => `<b>${escapeHTML(text)}</b>`;
// Steam Guard stages are explained as an icon, a one-line title and numbered steps, so the person
// knows which device to pick up and what to press. A plain password prompt needs no guide: the
// labelled field and the footer note say everything.
function signInGuide(job, account) {
  const who = strong(account || t('your account'));
  // Steps are inserted as markup so the bold cues survive; the bold text itself is escaped by strong().
  const guides = {
    mobileApproval: { icon: 'smartphone', title: t('Approve the sign-in on your phone'), steps: [
      t('Open the Steam app on your phone and tap {guard}, the shield tab at the bottom.', { guard: strong(t('Steam Guard')) }),
      t('A request to sign in as {account} is waiting there. Approve it.', { account: who }),
      t('If Steam asks {question}, choose {client}. This app signs in through Valve’s SteamCMD, which counts as the Steam client.', { question: strong(t('Where are you trying to sign in?')), client: strong(t('Steam Client')) }),
      t('Then come back here. The dialog continues once Steam confirms.'),
    ], note: t('Only approve a request you just started. Deny anything you do not recognise.'), phone: true },
    authenticatorCode: { icon: 'smartphone', title: t('Enter the code from the Steam app'), steps: [
      t('Open the Steam app on your phone and tap {guard}, the shield tab at the bottom.', { guard: strong(t('Steam Guard')) }),
      t('Read the five-character code shown at the top. It changes every 30 seconds.'),
      t('Type it below and submit before it changes. If it has already changed, use the new one.'),
    ], note: t('Don’t share this code with anyone. Enter it only here.'), phone: true },
    emailCode: { icon: 'mail', title: t('Enter the code Steam emailed you'), steps: [
      t('Check the inbox of the email address registered to this Steam account. Look in spam or junk too.'),
      t('Open the newest Steam Guard message. Every sign-in attempt sends a fresh code, so older ones no longer work.'),
      t('Type the five-character code below and submit it.'),
    ], note: t('Steam never asks for your password by email. Enter the code only here.'), mail: true },
    unknown: { icon: 'shield', title: t('Verify with the method Steam requested'), steps: [
      t('Follow the verification Steam asked for in its app or email, then continue here.'),
      t('Never disable Steam Guard or share passwords or recovery codes.'),
    ], phone: true },
  };
  if (job.challenge) return guides[job.challenge] || guides.unknown;
  return job.prompt && !job.securePrompt ? guides.unknown : null;
}
const guideMarkup = (guide, extra = '') => `<section class="dialog-guide" aria-label="${escapeHTML(guide.title)}"><span class="dialog-guide-icon">${icon(guide.icon, 20)}</span><div class="dialog-guide-body"><p class="dialog-guide-title" role="status">${escapeHTML(guide.title)}</p>${guide.steps?.length ? `<ol class="dialog-steps">${guide.steps.map(step => `<li><span>${step}</span></li>`).join('')}</ol>` : ''}${guide.note ? `<p class="dialog-guide-note">${escapeHTML(guide.note)}</p>` : ''}${extra}</div></section>`;
function queueState() {
  // A finished sign-in-only session is not a download; it only shows while it is running.
  const pixivDownloads = (state.pixiv?.downloads || []).map(job => ({ ...job, source: 'pixiv',
    wallpaperID: job.id, queued: job.status === 'waiting', paused: job.status === 'paused',
    cancelled: job.status === 'cancelled', bytesReceived: job.received, bytesExpected: job.expected,
    status: job.status === 'paused' ? t('Download paused') : job.status === 'waiting' ? t('Waiting to download') : job.status === 'installing' ? t('Saving to your library…') : job.status === 'finished' ? t('In your library') : job.status === 'failed' ? job.error : job.status === 'cancelled' ? t('Download cancelled.') : t('Downloading'),
  }));
  const downloads = [...(state.downloads || []).filter(item => item.id !== SIGN_IN_ID || item.pending), ...pixivDownloads];
  const requests = state.downloadRequests || [];
  const active = downloads.filter(item => item.pending && !item.queued);
  const queued = downloads.filter(item => item.pending && item.queued);
  const attention = downloads.filter(item => item.prompt || item.challenge || item.error);
  // Several downloads can run at once: the activity bar carries one job's own figures, or the
  // batch's mean progress and summed speed once more than one is running.
  const running = active[0];
  const measured = active.filter(item => Number.isFinite(item.progress));
  const progress = measured.length ? clamp(measured.reduce((sum, item) => sum + clamp(item.progress), 0) / measured.length) : null;
  const percent = progress === null ? null : Math.round(progress * 100);
  const speed = active.reduce((sum, item) => sum + (Number.isFinite(item.bytesPerSecond) ? item.bytesPerSecond : 0), 0);
  // The batch is done when its slowest job is, so one job without an estimate leaves the batch without one.
  const remaining = active.length && active.every(item => Number.isFinite(item.secondsRemaining)) ? timeLeft(Math.max(...active.map(item => item.secondsRemaining))) : '';
  const count = requests.length + active.length + queued.length;
  const summary = active.length > 1 ? [t('{count} downloading', { count: active.length }), percent !== null ? `${percent}%` : '', speed > 0 ? rate(speed) : '', remaining].filter(Boolean).join(' · ') : running ? [running.status || t('Downloading'), percent !== null ? `${percent}%` : '', rate(running.bytesPerSecond), remaining].filter(Boolean).join(' · ') : requests.length ? t(requests.length === 1 ? '{count} download needs setup' : '{count} downloads need setup', { count: requests.length }) : queued.length ? t('{count} waiting to download', { count: queued.length }) : downloads.length ? t(downloads.length === 1 ? '{count} download' : '{count} downloads', { count: downloads.length }) : t('No downloads');
  return { downloads, requests, active, queued, attention, progress, percent, count, summary };
}
function queueButton() {
  const { downloads, requests, attention, count, summary } = queueState();
  // Tiles and the activity bar carry download state; the top-bar button only appears once there is a list to open.
  if (!downloads.length && !requests.length) return '';
  const label = t('Downloads: {summary}', { summary: attention.length ? t('{summary} · needs attention', { summary }) : summary });
  return `<button type="button" data-action="openDownloads" class="quiet icon-button queue-button" aria-haspopup="dialog" aria-expanded="${popover === 'downloads'}" title="${escapeHTML(label)}" aria-label="${escapeHTML(label)}">${icon('download')}${count ? `<span class="queue-badge${attention.length ? ' attention' : ''}" aria-hidden="true">${count}</span>` : ''}</button>`;
}
function renderActivity() {
  const { summary, attention, active, progress } = queueState();
  const hasWallpaper = (state.displays || []).some(display => Boolean(display.wallpaperID));
  const downloadSummary = attention.length ? t('{summary} · needs attention', { summary }) : summary;
  const report = state.import?.report;
  const importResult = report ? t('{imported} imported · {skipped} skipped', { imported: Number(report.imported), skipped: Number(report.skipped) }) : t('Import wallpapers');
  const importSummary = state.import?.busy ? state.import.status || t('Importing…') : report && (report.failures?.length || report.cancelled) ? t('{summary} · needs attention', { summary: importResult }) : importResult;
  const showImport = state.import?.busy || (report && importReportUnseen) || (popover === 'import' && popoverTrigger.startsWith('#activity-bar '));
  const transferring = active.filter(item => !item.authenticating);
  const label = transferring.length === 1 ? t('{title} download progress', { title: transferring[0].title }) : t('{count} downloads progress', { count: transferring.length });
  morph($('activity-bar'), `<div class="activity-left">${button('', 'previousWallpaper', { displayID: state.targetDisplayID }, { icon: 'chevronLeft', title: t('Previous wallpaper'), className: 'quiet icon-button', disabled: !state.history?.previousID || !state.displays?.some(display => display.id === state.targetDisplayID && display.enabled && display.mode !== 'mirror') })}${button('', 'playback', {}, { icon: !hasWallpaper || state.paused ? 'play' : 'pause', title: !hasWallpaper ? t('No wallpaper playing') : state.paused ? t('Resume wallpaper playback') : t('Pause wallpaper playback'), className: 'quiet icon-button', disabled: state.busy || !hasWallpaper })}<span class="activity-copy">${escapeHTML(!hasWallpaper ? t('No wallpaper playing') : state.paused ? t('Playback paused') : t('Playback running'))}</span>${button(t('Recently used'), 'openHistory', {}, { className: 'quiet', expanded: popover === 'history', controls: 'history-popover' })}</div><div class="activity-right">${showImport ? button(importSummary, 'openImport', {}, { icon: 'folder', className: 'quiet', title: importSummary }) : ''}${state.setup?.busy ? `<span class="activity-copy">${escapeHTML(t('Setting up SteamCMD…'))}</span>` : ''}${pixivActivity()}${transferring.length ? `<progress class="activity-progress" max="1"${progress !== null ? ` value="${progress}"` : ''} aria-label="${escapeHTML(label)}"></progress>` : ''}${button(downloadSummary, 'openDownloads', {}, { icon: 'download', className: 'quiet', title: downloadSummary })}</div>`);
}
// pixiv downloads are the app's own and brief, so they are not rows in the Steam downloads list;
// while one runs, the activity bar says so on every tab and leads back to the pixiv tab.
function pixivActivity() {
  const jobs = (state.pixiv?.downloads || []).filter(job => job.pending);
  if (!jobs.length) return '';
  const percent = jobs.length === 1 && Number.isFinite(jobs[0].progress) ? Math.round(clamp(jobs[0].progress) * 100) : null;
  const summary = jobs.length === 1 ? t('pixiv: {title}', { title: jobs[0].title || t('Untitled') }) + (percent === null ? '' : ` · ${percent}%`) : t('{count} pixiv downloads', { count: jobs.length });
  return button(summary, 'navigate', { page: 'pixiv' }, { icon: 'download', className: 'quiet', title: summary });
}
function libraryThumb(item) { const still = libraryStill(item); return previewThumb(still.source, still.fallback); }
function previewThumb(url, fallback = '') {
  const source = safeImage(url);
  return `<span class="thumb-placeholder">${icon('image', 15)}</span>${source ? `<img ${keyAttr(source)} src="${escapeHTML(source)}" alt="" loading="lazy" decoding="async"${fallback ? ` data-fallback="${escapeHTML(fallback)}"` : ''} referrerpolicy="no-referrer">` : ''}`;
}
function renderPopover() {
  for (const [kind, id, markup] of [['downloads', 'queue-popover', queueMarkup], ['import', 'import-popover', importMarkup], ['history', 'history-popover', historyMarkup]]) {
    const node = $(id);
    node.hidden = popover !== kind;
    if (popover === kind) { morph(node, markup()); placePopover(node); }
  }
}
function historyMarkup() {
  const target = state.displays?.find(display => display.id === state.targetDisplayID);
  const wallpapers = new Map((state.wallpapers || []).map(item => [item.id, item]));
  const recent = (state.history?.recentIDs || []).map(id => wallpapers.get(id)).filter(Boolean);
  const available = target?.enabled && target.mode !== 'mirror';
  const rows = recent.map(item => `<li data-key="history-${escapeHTML(item.id)}"><button type="button" class="history-item" data-action="activate" data-id="${escapeHTML(item.id)}" aria-label="${escapeHTML(t('Apply {title}', { title: item.title }))}"${target?.wallpaperID === item.id ? ' aria-current="true"' : ''}${disabled(!available || busy('activate', { id: item.id }))}><span class="queue-thumb">${libraryThumb(item)}</span><span class="history-title">${escapeHTML(item.title)}</span>${target?.wallpaperID === item.id ? `<span class="history-active">${escapeHTML(t('Active'))}</span>` : ''}</button></li>`).join('');
  const body = rows ? `<ul class="queue-list history-list">${rows}</ul>` : `<p class="queue-empty">${escapeHTML(t('No recent wallpapers for this display. Apply a wallpaper to start its history.'))}</p>`;
  return `<div class="popover-heading"><h2 id="history-popover-title">${escapeHTML(t('Recently used'))}</h2>${button('', 'closePopover', {}, { icon: 'close', title: t('Close history'), className: 'quiet icon-button' })}</div><p class="history-display">${escapeHTML(target?.title || '')}</p>${body}<div class="popover-footer"><p class="queue-note">${escapeHTML(t('Keeps the last 50 wallpapers used on this display.'))}</p>${recent.length ? button(t('Clear history'), 'historyClear', { displayID: state.targetDisplayID }, { className: 'quiet', disabled: !available }) : ''}</div>`;
}
function queueMarkup() {
  const { downloads, requests } = queueState();
  const active = downloads.filter(item => item.pending);
  // A failed or cancelled download is unfinished business: it stays visible with its recovery action.
  const unresolved = downloads.filter(item => !item.pending && needsReview(item));
  const succeeded = downloads.filter(item => !item.pending && !needsReview(item));
  const rows = [...requests.map(queueRequestRow), ...active.map(queueJobRow), ...unresolved.map(queueJobRow), ...(queueExpanded ? succeeded.map(queueJobRow) : [])].join('');
  const empty = succeeded.length ? t('All downloads are complete.') : t('No downloads yet. Pick a Workshop wallpaper and choose Download.');
  return `<div class="popover-heading"><h2 id="queue-popover-title">${escapeHTML(t('Downloads'))}</h2>${button('', 'closePopover', {}, { icon: 'close', title: t('Close downloads'), className: 'quiet icon-button' })}</div>${rows ? `<ul class="queue-list">${rows}</ul>` : `<p class="queue-empty">${escapeHTML(empty)}</p>`}<div class="popover-footer"><p class="queue-note">${escapeHTML(queueNote())}</p><div class="actions">${succeeded.length ? button(queueExpanded ? t('Hide completed') : t('Show completed ({count})', { count: succeeded.length }), 'toggleQueueHistory', {}, { className: 'link' }) : ''}${downloads.length > active.length ? button(t('Clear finished'), 'clearDownloads', {}, { className: 'quiet' }) : ''}${button(t('Show download logs'), 'showLogs', {}, { icon: 'folder', className: 'link' })}</div></div>`;
}
const queueNote = () => {
  if (!(state.downloads || []).some(job => job.id !== SIGN_IN_ID) && state.pixiv?.downloads?.length) return t('pixiv downloads run two at a time; paused downloads stay in the queue.');
  const slots = Number(state?.downloadSlots) || 1;
  return slots > 1 ? t('Up to {slots} downloads run at once and share your saved sign-in; the rest wait in order. Steam may still ask you to approve a sign-in.', { slots }) : t('Downloads run one at a time; the rest wait in order. Steam may still ask you to approve a sign-in.');
};
const needsReview = (item) => Boolean(item.error) || Boolean(item.cancelled) || Boolean(item.paused);
function queueRequestRow(request) {
  return `<li class="queue-row attention" ${keyAttr(`request-${request.id}`)}><span class="queue-thumb">${previewThumb(request.thumbnail || request.preview)}</span><div class="queue-body"><p class="queue-title">${escapeHTML(request.title)}</p><p class="queue-status">${escapeHTML(request.paused ? t('Download paused') : stageHint(request.stage))}</p><div class="actions">${button(request.paused ? t('Resume download') : t('Continue setup'), request.paused ? 'downloadResume' : 'continueSetup', { id: request.id }, { className: 'primary' })}${button('', 'removeDownloadRequest', { id: request.id }, { icon: 'close', title: t('Remove {title} from downloads', { title: request.title }), className: 'quiet icon-button' })}</div></div></li>`;
}
function queueJobRow(item) {
  const installedItem = (state.wallpapers || []).find(wallpaper => wallpaper.id === item.id);
  const percent = Number.isFinite(item.progress) ? Math.round(clamp(item.progress) * 100) : null;
  const running = item.pending && !item.queued;
  const needsAuth = running && Boolean(item.prompt || item.challenge);
  const review = !item.pending && needsReview(item);
  const jobAction = kind => item.source === 'pixiv' ? ({ pause: 'pixivPause', resume: 'pixivResume', cancel: 'pixivCancel', retry: 'pixivRetryDownload' })[kind] : ({ pause: 'downloadPause', resume: 'downloadResume', cancel: 'downloadCancel', retry: 'downloadRetry' })[kind];
  return `<li class="queue-row${needsAuth || review ? ' attention' : ''}" ${keyAttr(`job-${item.id}`)}><span class="queue-thumb">${previewThumb(item.thumbnail || item.preview)}</span><div class="queue-body"><p class="queue-title">${escapeHTML(item.title)}</p><p class="queue-status">${escapeHTML(item.status)}${running && transfer(item) ? ` · ${transfer(item)}` : ''}</p>${running ? `<progress max="1"${percent === null ? '' : ` value="${clamp(item.progress)}"`} aria-label="${escapeHTML(t('{title} download progress', { title: item.title }))}"></progress>` : ''}${item.error ? `<p class="notice error" role="alert">${escapeHTML(item.error)}</p>` : ''}${item.warning ? `<p class="notice warning">${escapeHTML(item.warning)}</p>` : ''}<div class="actions">${needsAuth ? button(t('Finish sign-in'), 'continueSetup', { id: item.id }, { icon: 'shield', className: 'primary' }) : ''}${item.pending && !item.paused && !item.signInOnly ? button(t('Pause download'), jobAction('pause'), { id: item.id }, { className: 'quiet' }) : ''}${item.pending || item.paused ? button(item.queued ? t('Remove from queue') : t('Cancel'), jobAction('cancel'), { id: item.id }, { className: 'quiet' }) : ''}${item.paused && !item.pending ? button(t('Resume download'), jobAction('resume'), { id: item.id }, { icon: 'play', className: 'primary' }) : review && !item.paused ? button(t('Try again'), jobAction('retry'), { id: item.id }, { icon: 'refresh', className: 'primary', disabled: item.source !== 'pixiv' && !state.setup?.ready }) : ''}${review && item.source !== 'pixiv' && !state.setup?.ready ? `<span class="queue-status">${escapeHTML(stageHint('setup'))}</span>` : ''}${installedItem ? `${button(t('Show in library'), 'showInstalled', { id: item.id }, { icon: 'image', className: 'link' })}${button(t('Show in Finder'), 'reveal', { id: item.id }, { icon: 'folder', className: 'link' })}` : ''}</div></div></li>`;
}
function importMarkup() {
  const status = state.import || {};
  const report = status.report;
  return `<div class="popover-heading"><h2 id="import-popover-title">${escapeHTML(t('Import wallpapers'))}</h2>${button('', 'closePopover', {}, { icon: 'close', title: t('Close import'), className: 'quiet icon-button' })}</div><div class="popover-body"><p class="muted">${escapeHTML(t('Choose wallpaper folders, videos, images or web pages. Imports copy the source files into your library and leave the originals untouched.'))}</p><p class="muted"><small>${escapeHTML(t('You can also drop them on WallpaperMachine in the Dock.'))}</small></p><label class="field">${escapeHTML(t('If a wallpaper already exists'))}<select id="import-duplicates"${disabled(status.busy)}>${selectOptions([['skip', t('Skip duplicates')], ['keepBoth', t('Keep both copies')], ['replaceChanged', t('Replace if changed')]], importDuplicates)}</select></label><div class="actions">${button(t('Choose wallpapers'), 'import', { duplicates: importDuplicates }, { icon: 'folder', className: 'primary', disabled: status.busy })}${status.busy ? button(t('Cancel import'), 'importCancel') : ''}</div>${status.busy ? `<progress aria-label="${escapeHTML(t('Importing…'))}"></progress>` : ''}${status.status ? `<p class="muted" role="status">${escapeHTML(status.status)}</p>` : ''}${report ? `<div class="import-controls" role="status"><p>${escapeHTML(t('{imported} imported · {skipped} skipped', { imported: Number(report.imported), skipped: Number(report.skipped) }))}${report.cancelled ? escapeHTML(t(' · Cancelled')) : ''}</p>${(report.failures || []).map(failure => `<p class="notice error">${escapeHTML(failure)}</p>`).join('')}</div>` : ''}</div>`;
}
function placePopover(node) {
  const trigger = popoverTrigger ? document.querySelector(popoverTrigger) : null;
  const rect = trigger?.getBoundingClientRect();
  if (!rect) return;
  const below = rect.bottom + 6;
  const available = Math.max(window.innerHeight - below - 8, rect.top - 14);
  node.style.maxHeight = `${Math.floor(Math.max(0, Math.min(560, available)))}px`;
  const width = node.offsetWidth;
  const height = node.offsetHeight;
  node.style.left = `${Math.round(Math.max(8, Math.min(rect.right - width, window.innerWidth - width - 8)))}px`;
  if (below + height <= window.innerHeight - 8) { node.style.top = `${Math.round(below)}px`; node.style.bottom = 'auto'; }
  else { node.style.top = 'auto'; node.style.bottom = `${Math.round(Math.max(8, window.innerHeight - rect.top + 6))}px`; }
}
function triggerSelector(trigger) {
  const action = trigger?.dataset?.action;
  if (!action) return '';
  const host = ['#top-actions', '#activity-bar', '#browser-toolbar', '#inspector', '#queue-popover'].find(id => trigger.closest(id));
  return `${host ? `${host} ` : ''}[data-action="${action}"]`;
}
function restorePanelFocus(selectors) {
  if (welcome.isOpen()) { $('welcome-title')?.focus(); return; }
  const target = selectors.filter(Boolean).map(selector => document.querySelector(selector)).find(node => node?.isConnected && !node.disabled && !node.closest('[inert]') && node.getClientRects().length && getComputedStyle(node).visibility !== 'hidden');
  target?.focus();
}
function openPopover(kind, trigger) {
  if (popover === kind) { closePopover(true); return; }
  if (popover === 'import') closePopover(false);
  popover = kind;
  queueExpanded = false;
  popoverTrigger = triggerSelector(trigger) || popoverTrigger;
  renderActivity();
  renderPopover();
  $({ downloads: 'queue-popover', import: 'import-popover', history: 'history-popover' }[kind]).focus();
}
function closePopover(restore) {
  if (!popover) return;
  const selector = popoverTrigger;
  if (popover === 'import') importReportUnseen = false;
  popover = null;
  queueExpanded = false;
  renderActivity();
  renderPopover();
  if (restore) restorePanelFocus([selector, '#browser-toolbar .import-button', '.tabs [aria-current="page"]']);
  supportPrompt.render(state);
}
function openDialog(id, trigger) {
  dialogTarget = id;
  dialogTrigger = triggerSelector(trigger) || dialogTrigger;
  seedAccount(id);
  closePopover(false);
  renderDialog();
}
// Each retained request owns its account, so switching requests can never submit another one's sign-in.
function seedAccount(id) {
  const request = requestByID(id);
  const job = jobByID(id);
  dialogAccount = { id, account: request?.account ?? job?.account ?? state?.account ?? state?.savedAccount ?? '', rememberSession: request?.rememberSession ?? Boolean(state?.rememberSession) };
  dialogError = null;
}
function closeDialog() {
  const node = $('download-dialog');
  const selector = dialogTrigger;
  for (const job of (state?.downloads || [])) if (job.pending && (job.prompt || job.challenge)) dismissedAuth.add(authKey(job));
  dialogTarget = null;
  dialogTrigger = null;
  dialogAccount = null;
  dialogError = null;
  dialogFocusKey = null;
  dialogHandoff = null;
  clearTimeout(handoffTimer);
  if (node.open) node.close();
  morph(node, '');
  node.removeAttribute('data-stage');
  // Closing must not leave focus stranded on the body, and must not pull it away from wherever the user went.
  if (!document.activeElement || document.activeElement === document.body) restorePanelFocus([selector, '#top-actions [data-action="openDownloads"]', '#activity-bar [data-action="openDownloads"]', '.tabs [aria-current="page"]']);
  supportPrompt.render(state);
}
// The dialog only ever opens from an explicit request, so a later snapshot never reopens it.
function renderDialog() {
  const node = $('download-dialog');
  if (dialogTarget === null) return;
  const request = requestByID(dialogTarget);
  const own = jobByID(dialogTarget);
  // An explicitly opened dialog stays put while a job logs in — including the shared-resources job this intent waits behind.
  const pendingAuth = (job) => job?.pending && !job.queued && (job.authenticating || job.prompt || job.challenge) ? job : null;
  const auth = pendingAuth(own) || (request || own?.queued ? pendingAuth(jobByID('scene-assets')) : null);
  const waiting = request && request.stage !== 'ready' ? request : null;
  // The moment a sign-in completes the transfer is already running; say so instead of closing mid-thought.
  const running = (job) => job?.pending && !job.error && !pendingAuth(job) ? job : null;
  const started = !waiting && !auth && (node.dataset.stage === 'auth' || dialogHandoff === dialogTarget) ? (own?.queued && running(jobByID('scene-assets'))) || running(own) : null;
  if (!waiting && !auth && !started) { closeDialog(); return; }
  if (started && dialogHandoff !== dialogTarget) { dialogHandoff = dialogTarget; clearTimeout(handoffTimer); handoffTimer = setTimeout(() => { if (dialogHandoff === dialogTarget && dialogTarget !== null) closeDialog(); }, 6000); }
  if (dialogAccount?.id !== dialogTarget) seedAccount(dialogTarget);
  const stage = waiting ? waiting.stage : started ? 'started' : 'auth';
  const open = node.open;
  const focused = document.activeElement;
  const previousTitle = $('download-dialog-title');
  const focusKey = JSON.stringify([dialogTarget, stage, auth?.prompt, auth?.challenge]);
  node.dataset.stage = stage;
  morph(node, dialogMarkup(stage, waiting || own || auth || started, auth || started));
  if (!open) node.showModal();
  if (!open || dialogFocusKey !== focusKey) {
    dialogFocusKey = focusKey;
    if (!open || !focused?.isConnected || focused.disabled || !node.contains(focused) || focused === previousTitle) {
      (node.querySelector('.dialog-body input:not([disabled])') || node.querySelector('.dialog-body .primary:not([disabled])') || $('download-dialog-title'))?.focus();
    }
  }
}
function dialogMarkup(stage, subject, auth) {
  const body = stage === 'setup' ? setupStep() : stage === 'account' ? accountStep() : stage === 'resources' ? resourcesStep() : stage === 'started' ? startedStep(auth, subject) : authStep(auth);
  const title = stage === 'auth' ? auth.challenge ? t('Verify this Steam sign-in') : auth.prompt ? t('Sign in to Steam') : t('Connecting to Steam') : stage === 'started' ? t('Signed in to Steam') : stageTitle(stage);
  const subtitle = (stage === 'auth' || stage === 'started') && auth.id !== subject.id ? t('{auth} · needed for {subject}', { auth: auth.title, subject: subject.title }) : subject.title;
  return `<div class="dialog-head"><span class="dialog-thumb">${previewThumb(stage === 'auth' ? auth.thumbnail || auth.preview || subject.thumbnail || subject.preview : subject.thumbnail || subject.preview)}</span><div class="dialog-heading"><h2 id="download-dialog-title" tabindex="-1">${escapeHTML(title)}</h2><p class="muted">${escapeHTML(subtitle)}</p></div>${button('', 'dismissDialog', {}, { icon: 'close', title: t('Close without removing this download'), className: 'quiet icon-button' })}</div><div class="dialog-body" data-stage="${stage}">${dialogError?.account === dialogAccount ? `<p class="notice error" role="alert" ${keyAttr('dialog-action-error')}>${escapeHTML(dialogError.message)}</p>` : ''}${body}</div>`;
}
function setupStep() {
  const setup = state.setup || {};
  const retained = setup.candidatePath ? setup.canApprove ? `<p class="notice">${escapeHTML(t('This downloaded copy needs your approval before it can run:'))}<br>${escapeHTML(setup.candidatePath)}</p>` : `<p class="notice warning">${escapeHTML(t('A downloaded copy is retained but not usable yet:'))}<br>${escapeHTML(setup.candidatePath)}</p>` : '';
  return `<p>${escapeHTML(t('SteamCMD is Valve’s download tool. Install it here, or point to a copy you already have. Installing it does not sign you in.'))}</p><p class="dialog-status" role="status">${escapeHTML(setup.status || (setup.ready ? t('SteamCMD is ready.') : t('SteamCMD is not installed yet.')))}</p>${setup.busy ? `<progress max="1"${Number.isFinite(setup.progress) ? ` value="${clamp(setup.progress)}"` : ''} aria-label="${escapeHTML(t('SteamCMD installation progress'))}"></progress>` : ''}${setup.error ? `<p class="notice error" role="alert">${escapeHTML(setup.error)}</p>` : ''}${retained}<div class="dialog-actions">${button(t('Locate a copy'), 'setupLocate', {}, { icon: 'folder', disabled: setup.busy })}${setup.busy && setup.canCancel !== false ? button(t('Cancel setup'), 'setupCancel') : ''}${button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' })}${setup.canApprove ? button(t('Allow this SteamCMD'), 'setupApprove', {}, { icon: 'shield', className: 'primary', disabled: setup.busy }) : button(setup.error ? t('Try again') : t('Install SteamCMD'), 'setupInstall', {}, { icon: setup.error ? 'refresh' : 'download', className: 'primary', disabled: setup.busy })}</div>${setup.candidatePath ? `<div class="dialog-actions">${button(t('Show it in Finder'), 'setupRevealCandidate', {}, { icon: 'folder', className: 'link' })}${button(t('Discard it'), 'setupDiscardCandidate', {}, { className: 'link', disabled: setup.busy })}</div>` : ''}<p class="dialog-note">${escapeHTML(t('Approval applies only to the exact copy you allow. Gatekeeper and signature checks stay in force.'))}</p>`;
}
function accountStep() {
  const working = busy('continueDownload', { id: dialogTarget });
  return `<form class="dialog-form" data-form="dialogContinue" ${keyAttr('dialog-account')}><label class="field">${escapeHTML(t('Steam account name'))}<input data-input="account" type="text" autocomplete="username" autocapitalize="off" spellcheck="false" value="${escapeHTML(dialogAccount.account)}"${disabled(working)}></label><label class="check-label"><input type="checkbox" data-change="rememberSession"${checked(dialogAccount.rememberSession)}${disabled(working)}>${escapeHTML(t('Keep me signed in on this Mac'))}</label>${state.savedAccount ? `<p class="dialog-note">${escapeHTML(t('Saved sign-in on this Mac: {account}', { account: state.savedAccount }))}${dialogAccount.account.trim().toLowerCase() === String(state.savedAccount).trim().toLowerCase() ? escapeHTML(t(' · will be reused')) : ''}</p>` : ''}<div class="dialog-actions">${button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' })}<button type="submit" class="primary"${disabled(working || !dialogAccount.account.trim())}>${icon('chevronRight')}<span class="button-label">${escapeHTML(t('Continue'))}</span></button></div><p class="dialog-note">${escapeHTML(t('Your password and any Steam Guard code come next. This app never saves them.'))}</p></form>`;
}
// The resources stage is a choice, so each path is one button carrying its own title and the one
// fact that decides it, instead of a paragraph of caveats above a row of buttons.
const choiceButton = (action, args, glyph, title, note, off) => `<button type="button" class="dialog-choice" data-action="${action}" ${Object.entries(args).map(([key, value]) => `data-${key}="${escapeHTML(value)}"`).join(' ')}${disabled(off)}><span class="dialog-guide-icon">${icon(glyph, 18)}</span><span class="dialog-choice-body"><span class="dialog-choice-title">${escapeHTML(title)}</span><span class="dialog-choice-note">${escapeHTML(note)}</span></span>${icon('chevronRight', 16)}</button>`;
function resourcesStep() {
  const settings = state.settings || {};
  const lead = settings.sceneAssetsReady ? t('Shared resources are already installed. Downloading again replaces them.') : t('Scene wallpapers need shaders and materials from Wallpaper Engine. This is a one-time setup.');
  return `<p${settings.sceneAssetsReady ? ' class="dialog-status" role="status"' : ''}>${escapeHTML(lead)}</p>${settings.sceneAssetsWarning ? `<p class="notice warning">${escapeHTML(settings.sceneAssetsWarning)}</p>` : ''}<div class="dialog-choices">${choiceButton('consentResources', { id: dialogTarget }, 'download', t('Download from Steam'), t('Needs a Steam account that owns Wallpaper Engine and several gigabytes free while downloading.'), busy('continueDownload', { id: dialogTarget }))}${choiceButton('locateAssets', {}, 'folder', t('Use an existing installation'), t('Already have Wallpaper Engine installed? Choose its folder instead of downloading.'), state.setup?.busy)}</div><div class="dialog-actions">${button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' })}</div>`;
}
function authStep(job) {
  const working = busy('downloadInput', { id: job.id });
  const waiting = !job.prompt && !job.challenge;
  const account = job.account || dialogAccount?.account || '';
  const guide = signInGuide(job, account);
  const identity = `<div class="dialog-identity"><p>${icon('userRound', 14)}<span>${t('Signing in as {account}', { account: `<span class="dialog-account">${escapeHTML(account || t('an unnamed account'))}</span>` })}</span></p>${button(t('Change account'), 'changeAccount', { id: job.id }, { className: 'link' })}</div>`;
  const connecting = guideMarkup({ icon: 'logIn', title: job.status, note: t('Contacting Steam. Password and Steam Guard prompts appear here.') }, `<progress aria-label="${escapeHTML(t('Connecting to Steam'))}"></progress>`);
  const help = guide?.phone ? button(t('Get the Steam mobile app'), 'openExternal', { url: 'https://store.steampowered.com/mobile' }, { icon: 'external', className: 'link' }) : guide?.mail ? button(t('Help with emailed codes'), 'openExternal', { url: 'https://help.steampowered.com/en/wizard/HelpWithSteamGuardCode' }, { icon: 'external', className: 'link' }) : '';
  return `${identity}${waiting ? connecting : guide ? guideMarkup(guide) : ''}${job.error ? `<p class="notice error" role="alert">${escapeHTML(job.error)}</p>` : ''}${job.warning ? `<p class="notice warning">${escapeHTML(job.warning)}</p>` : ''}${job.prompt ? `<form class="dialog-form" data-form="dialogAuth" data-id="${escapeHTML(job.id)}" ${keyAttr(`auth-${job.id}-${job.prompt}`)}><label class="field" for="dialog-response">${escapeHTML(t(job.prompt))}<input id="dialog-response" name="response" type="${job.securePrompt ? 'password' : 'text'}" autocomplete="off" spellcheck="false" autocapitalize="off" required${disabled(working)}></label><div class="dialog-actions">${button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' })}<button type="submit" class="primary"${disabled(working)}>${icon(job.securePrompt ? 'lock' : 'keyRound')}<span class="button-label">${escapeHTML(t('Submit'))}</span></button></div></form>` : ''}<div class="dialog-actions">${!job.prompt ? button(t('Not now'), 'dismissDialog', {}, { className: 'quiet' }) : ''}${button(t('Cancel this download'), 'downloadCancel', { id: job.id }, { className: 'quiet' })}${help}</div><p class="dialog-note">${escapeHTML(t('Only approve sign-ins you started yourself. Never share your password or recovery codes.'))}</p>`;
}
// Sign-in complete: the download is already running, so the dialog says so with live progress
// instead of vanishing, then steps aside on its own.
function startedStep(job, subject) {
  const shared = job.id !== subject.id;
  const guide = job.id === SIGN_IN_ID
    ? { icon: 'check', title: t('Signed in to Steam'), note: t('Downloads will use this sign-in.') }
    : { icon: 'check', title: shared ? t('Signed in. Shared resources are downloading first') : t('Signed in. {title} is downloading', { title: subject.title }), note: shared ? t('{title} starts automatically once they are installed. You can keep using the app meanwhile.', { title: subject.title }) : t('You can keep using the app. Progress shows on the wallpaper and in the downloads list.') };
  const progress = Number.isFinite(job.progress) ? `<progress max="1" value="${clamp(job.progress)}" aria-label="${escapeHTML(t('Download progress'))}"></progress>` : `<progress aria-label="${escapeHTML(t('Download in progress'))}"></progress>`;
  return `${guideMarkup(guide, `<p class="dialog-status" role="status">${escapeHTML(job.status)}</p>${progress}`)}<div class="dialog-actions">${button(t('Show downloads'), 'showDownloadsFromDialog', {}, { icon: 'download', className: 'quiet' })}${button(t('Done'), 'dismissDialog', {}, { icon: 'check', className: 'primary' })}</div>`;
}
let importDuplicates = 'skip';
async function searchWorkshop() { clearTimeout(searchTimer); await send('workshopSearch', { ...workshopDraft, tags: [...workshopDraft.tags], excludedTags: [...workshopDraft.excludedTags] }); }
async function commitProperty(element) {
  const { id, propertyId } = element.dataset;
  let value = element.type === 'checkbox' ? element.checked : element.type === 'range' || element.type === 'number' ? Number(element.value) : element.tagName === 'SELECT' ? JSON.parse(element.value) : element.value;
  if (typeof value === 'number' && !Number.isFinite(value)) return;
  await commitPropertyValue(id, propertyId, value);
}
async function commitPropertyValue(id, propertyId, value) {
  const key = draftKey(id, propertyId);
  drafts.set(key, value);
  // A step of the drag that is still on its way lands before the value that counts, never after it.
  await propertyDrag.end();
  await send('property', { id, propertyID: propertyId, value });
  if (drafts.get(key) === value) drafts.delete(key);
  render();
}
// One click keeps the intent: the native side retains the request and the dialog only collects what is still missing.
// With `apply`, native applies the wallpaper to the target display once it has arrived, unless the person chooses another meanwhile.
async function requestDownload(id, element, apply = false) {
  await send('requestDownload', apply ? { id, apply: true } : { id });
  const target = id === null ? 'scene-assets' : id;
  const request = requestByID(target);
  const job = jobByID(target);
  if (request && request.stage !== 'ready') openDialog(request.id, element);
  else if (job?.pending && !job.queued && (job.prompt || job.challenge)) openDialog(target, element);
}
const authKey = (job) => `${job.id}\u0000${job.prompt || job.challenge || ''}`;
// A password or Steam Guard request is the one thing a download cannot finish by itself, so it
// opens the dialog on its own. A saved sign-in never asks, so routine downloads stay on the tile.
function surfaceAuthRequests() {
  if (dialogTarget !== null || !state) return;
  // The welcome guide answers its own sign-in's prompts while it is open.
  const job = (state.downloads || []).find(item => item.pending && !item.queued && (item.prompt || item.challenge) && !(item.id === SIGN_IN_ID && welcome.isOpen()));
  if (job && !dismissedAuth.has(authKey(job))) openDialog(job.id, null);
}
async function continueDownload(includeResources) {
  const id = dialogTarget;
  if (!id) return;
  await sendDialog('continueDownload', { id, account: dialogAccount.account.trim(), rememberSession: dialogAccount.rememberSession, includeResources });
}
async function handleAction(action, data, element) {
  if (action.startsWith('pixiv')) return pixiv.handleAction(action, data);
  // Collections and presets keep their own page state; anything they do not own falls through.
  if (action.startsWith('collection') && await collections.handleAction(action, data)) return;
  if ((action.startsWith('preset') || action.startsWith('wallpaperPreset')) && await presets.handleAction(action, data)) return;
  const deliver = element?.closest('#download-dialog') ? sendDialog : send;
  const id = data.id;
  switch (action) {
    case 'dismissError':
      localError = '';
      if (state) { state.error = null; state.downloadError = null; }
      renderError();
      // The native side owns bridge errors, so a dismissal must reach it or the next snapshot restores it.
      await deliver('dismissError');
      return;
    case 'openDownloads': openPopover('downloads', element); return;
    case 'openHistory': openPopover('history', element); return;
    case 'showDownloadsFromDialog': { const trigger = dialogTrigger; closeDialog(); openPopover('downloads', document.querySelector('#top-actions [data-action="openDownloads"]') || (trigger ? document.querySelector(trigger) : null)); return; }
    case 'openImport': openPopover('import', element); return;
    case 'closePopover': closePopover(true); return;
    case 'toggleQueueHistory': queueExpanded = !queueExpanded; renderPopover(); return;
    case 'requestDownload': await requestDownload(id, element); return;
    case 'requestDownloadAndApply': await requestDownload(id, element, true); return;
    case 'requestAssets': await requestDownload(null, element); return;
    case 'continueSetup': openDialog(id, element); return;
    // Native builds the links and opens the share menu under the button.
    case 'shareWallpaper': await send('shareWallpaper', { id, rect: elementRect(element) }); return;
    case 'dismissDialog': closeDialog(); return;
    case 'consentResources': await continueDownload(true); return;
    // Native cancels this exact job and hands the same intent back at the account stage, so the dialog simply follows it.
    case 'changeAccount': await deliver('changeDownloadAccount', { id }); openDialog(id, element); return;
    case 'removeDownloadRequest': if (dialogTarget === id) closeDialog(); await deliver(action, { id }); return;
    case 'clearInstalledSearch': installed.text = ''; // falls through to reset filters
    case 'clearInstalled': installed.tags = []; installed.excludedTags = []; collections.clearFilter(); render(); return;
    case 'toggleSelect': toggleSelection(id); return;
    case 'toggleSelecting': selecting = !selecting; if (!selecting) { selection.clear(); selectionAnchor = null; } render(); return;
    case 'selectAllVisible': for (const item of visibleWallpapers()) selection.add(item.id); selectionAnchor ??= [...selection][0] ?? null; renderGrid(false); return;
    case 'clearSelection': selection.clear(); selectionAnchor = null; renderGrid(false); return;
    case 'dragSelectLearned': learnSweep(); return;
    case 'deleteSelected': if (selection.size) await deliver('deleteMany', { ids: [...selection] }); return;
    case 'addSelectedToPlaylist': if (selection.size) await deliver('playlistAdd', { ids: [...selection] }); return;
    case 'playlistAdd': await deliver(action, { ids: [id] }); return;
    case 'clearWorkshopSearch': workshopDraft.text = ''; // falls through to reset filters
    case 'clearWorkshop': workshopDraft.tags = []; workshopDraft.excludedTags = [...defaultExcludedTags]; render(); await searchWorkshop(); return;
    case 'includeSection': case 'excludeSection': setExcluded(filterDraft(state.page === 'discover'), excludeSections.find(section => section.key === data.section)?.tags.map(entry => tagEntry(entry).tag) || [], action === 'excludeSection'); await applyFilterChange(); return;
    case 'showInstalled': await deliver('navigate', { page: 'installed' }); await deliver('select', { id }); return;
    case 'clearProperty': await deliver('property', { id, propertyID: data.propertyId, value: '' }); return;
    case 'restoreProperty': drafts.delete(draftKey(id, data.propertyId)); await deliver(action, { id, propertyID: data.propertyId }); return;
    case 'restoreAllProperties': for (const key of [...drafts.keys()]) if (key.startsWith(`${id}\u0000`)) drafts.delete(key); await deliver(action, { id }); return;
    case 'revert': for (const key of drafts.keys()) if (key.startsWith(`${id}\u0000`)) drafts.delete(key); await deliver(action, { id }); return;
    case 'activate': case 'reapplyWallpaper': case 'activateAll':
      try { await deliver(action, { id }); activationFailures.delete(id); } catch (error) {
        activationFailures.set(id, error?.message || String(error));
        // Putting the displays back selects the wallpapers they showed; stay on the one that failed, where its notice is.
        if (action === 'activateAll') await deliver('select', { id }).catch(() => {});
        throw error;
      } finally { render(); }
      return;
    case 'previewWallpaper': {
      const texts = new Set((state.options?.id === id ? state.options.properties : []).filter(property => property.kind === 'textInput' && property.enabled !== false).map(property => property.id));
      const properties = Object.fromEntries([...drafts].filter(([key, value]) => key.startsWith(`${id}\u0000`) && typeof value === 'string' && texts.has(key.split('\u0000')[1])).map(([key, value]) => [key.split('\u0000')[1], value]));
      await deliver(action, { id, properties });
      return;
    }
    case 'apply':
      for (const [key, value] of [...drafts]) if (key.startsWith(`${id}\u0000`)) { await deliver('property', { id, propertyID: key.split('\u0000')[1], value }); if (drafts.get(key) === value) drafts.delete(key); }
      await deliver(action, { id }); return;
    case 'navigate': await deliver(action, { page: data.page }); return;
    case 'refreshWorkshop': await searchWorkshop(); return;
    case 'workshopCreator': await deliver(action, { id, name: data.name || '' }); $('wallpaper-grid').scrollTop = 0; return;
    case 'workshopCollection': await deliver(action, { id, title: data.title ?? state.workshop.items.find(item => item.id === id)?.title ?? '' }); $('wallpaper-grid').scrollTop = 0; return;
    case 'workshopBack': await deliver(action); $('wallpaper-grid').scrollTop = 0; return;
    case 'workshopSource': await deliver(action, { source: data.source }); $('wallpaper-grid').scrollTop = 0; return;
    case 'toggleFilters': await deliver('filters', { page: state.page, collapsed: !filtersCollapsed() }); return;
    case 'toggleSortDirection': installed.descending = !installed.descending; render(); return;
    case 'workshopPage': await deliver(action, { page: Math.min(workshopMaxPages(), Math.max(1, Number(data.workshopPage) || 1)) }); $('wallpaper-grid').scrollTop = 0; return;
    case 'openExternal': await deliver(action, { url: data.url }); return;
    case 'openPerformance': revealSettingsSection('performance'); await deliver('navigate', { page: 'settings' }); return;
    case 'import': await deliver(action, { duplicates: importDuplicates }); return;
    default: {
      const args = {};
      if (id !== undefined) args.id = id;
      if (data.propertyId !== undefined) args.propertyID = data.propertyId;
      if (data.displayId !== undefined) args.displayID = data.displayId;
      await deliver(action, args);
    }
  }
}
function toggleSelection(id, { range = false } = {}) {
  if (range && selectionAnchor) {
    const ids = visibleWallpapers().map(item => item.id);
    const [from, to] = [ids.indexOf(selectionAnchor), ids.indexOf(id)];
    if (from >= 0 && to >= 0) { for (const each of ids.slice(Math.min(from, to), Math.max(from, to) + 1)) selection.add(each); renderGrid(false); return; }
  }
  if (!selection.delete(id)) selection.add(id);
  selectionAnchor = selection.has(id) ? id : selectionAnchor;
  renderGrid(false);
}
// Press-and-sweep selection on Installed. Holding a tile still for a moment checks it (or, if it
// was checked, clears it) and every tile the pointer then sweeps over follows suit. The swept
// range runs from the pressed tile to the one under the pointer in grid order, so a fast sweep
// never skips a tile and sweeping back gives the overshoot back. Outside a selection the hold is
// required, so a stray drag changes nothing; once a selection is under way, or from a tile's check
// box, moving onto another tile starts the sweep at once. Near the grid's top or bottom edge the
// grid scrolls under the pointer.
const SWEEP_HOLD_MS = 350, SWEEP_SLOP = 6, SWEEP_EDGE = 48, SWEEP_INSET = 16;
function sweepArmingID() { return sweep && !sweep.painting && !sweep.moved ? sweep.startID : null; }
function sweepTileAt(x, y) { return document.elementFromPoint(x, y)?.closest('#wallpaper-grid .wallpaper-tile')?.dataset.key ?? null; }
function beginSweep() {
  clearTimeout(sweep.timer);
  Object.assign(sweep, { painting: true, ids: visibleWallpapers().map(item => item.id), base: new Set(selection), add: !selection.has(sweep.startID), spread: 0, last: null });
  $('wallpaper-grid').classList.add('sweeping');
  paintSweep(sweep.startID);
  sweep.frame = requestAnimationFrame(sweepFrame);
}
function paintSweep(id) {
  if (!id || id === sweep.last) return;
  const from = sweep.ids.indexOf(sweep.startID), to = sweep.ids.indexOf(id);
  if (from < 0 || to < 0) return;
  sweep.last = id;
  sweep.spread = Math.max(sweep.spread, Math.abs(to - from) + 1);
  selection.clear();
  for (const each of sweep.base) selection.add(each);
  for (const each of sweep.ids.slice(Math.min(from, to), Math.max(from, to) + 1)) { if (sweep.add) selection.add(each); else selection.delete(each); }
  if (sweep.add) selectionAnchor = sweep.startID; else if (!selection.has(selectionAnchor)) selectionAnchor = null;
  renderGrid(false);
}
// The further past the edge band the pointer rests, the faster the grid scrolls; the tile that
// scrolls beneath it joins the sweep.
function sweepFrame() {
  if (!sweep?.painting) return;
  const grid = $('wallpaper-grid'), box = grid.getBoundingClientRect();
  const below = sweep.y - (box.bottom - SWEEP_EDGE), above = box.top + SWEEP_EDGE - sweep.y;
  const step = below > 0 ? Math.min(below, SWEEP_EDGE * 2) / 3 : above > 0 ? -Math.min(above, SWEEP_EDGE * 2) / 3 : 0;
  const before = grid.scrollTop;
  if (step) grid.scrollTop += step;
  if (grid.scrollTop !== before) paintSweep(sweepTileAt(Math.min(Math.max(sweep.x, box.left + SWEEP_INSET), box.right - SWEEP_INSET), Math.min(Math.max(sweep.y, box.top + SWEEP_INSET), box.bottom - SWEEP_INSET)));
  sweep.frame = requestAnimationFrame(sweepFrame);
}
function endSweep() {
  if (!sweep) return;
  const { painting, spread, timer, frame } = sweep;
  clearTimeout(timer);
  cancelAnimationFrame(frame);
  sweep = null;
  const grid = $('wallpaper-grid');
  grid.classList.remove('sweeping');
  for (const tile of grid.querySelectorAll('.wallpaper-tile.arming')) tile.classList.remove('arming');
  if (!painting) return;
  // The press already did its work; the click that ends it must not toggle the tile back.
  swallowClick = true;
  setTimeout(() => { swallowClick = false; }, 0);
  if (spread > 1) learnSweep();
}
// Sweeping across two or more tiles once, or dismissing the tip, retires the tip for good.
function learnSweep() {
  if (!state || state.dragSelectLearned) return;
  state.dragSelectLearned = true;
  renderGrid(false);
  run(send('dragSelectLearned'));
}
$('wallpaper-grid').addEventListener('pointerdown', event => {
  endSweep();
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || state?.page !== 'installed') return;
  const tile = event.target.closest('.wallpaper-tile');
  if (!tile || event.target.closest('.tile-favorite')) return;
  sweep = { pointerId: event.pointerId, startID: tile.dataset.key, x0: event.clientX, y0: event.clientY, x: event.clientX, y: event.clientY, eager: selecting || selection.size > 0 || Boolean(event.target.closest('.tile-check')), painting: false, moved: false };
  tile.classList.add('arming');
  sweep.timer = setTimeout(beginSweep, SWEEP_HOLD_MS);
});
document.addEventListener('pointermove', event => {
  if (!sweep || event.pointerId !== sweep.pointerId) return;
  // The button came up outside the window, where no pointerup reached the page.
  if (!(event.buttons & 1)) { endSweep(); return; }
  sweep.x = event.clientX; sweep.y = event.clientY;
  const id = sweepTileAt(sweep.x, sweep.y);
  if (sweep.painting) { paintSweep(id); return; }
  if (!sweep.moved && Math.hypot(sweep.x - sweep.x0, sweep.y - sweep.y0) > SWEEP_SLOP) {
    // Moving gives up the hold: an ordinary drag outside a selection is left alone.
    if (!sweep.eager) { endSweep(); return; }
    sweep.moved = true;
    clearTimeout(sweep.timer);
    $('wallpaper-grid').querySelector('.wallpaper-tile.arming')?.classList.remove('arming');
  }
  if (sweep.eager && id && id !== sweep.startID) { beginSweep(); paintSweep(id); }
});
for (const type of ['pointerup', 'pointercancel']) document.addEventListener(type, event => { if (sweep && event.pointerId === sweep.pointerId) endSweep(); });
window.addEventListener('blur', endSweep);
// A tile's artwork would otherwise start a native image drag instead of the sweep.
$('wallpaper-grid').addEventListener('dragstart', event => { if (state?.page === 'installed') event.preventDefault(); });
// The top bar doubles as the window's title bar: plain presses on its background move the
// window and double-clicks follow the system title-bar action. Controls keep their own clicks.
function titleBarGesture(event) { return event.button === 0 && !event.target.closest('button, select, input, textarea, a, label, [role="dialog"]'); }
function postTitleBarGesture(action) { const bridge = window.webkit?.messageHandlers?.native; if (bridge) Promise.resolve(bridge.postMessage({ action })).catch(() => {}); }
document.querySelector('.topbar').addEventListener('mousedown', event => { if (!titleBarGesture(event)) return; event.preventDefault(); postTitleBarGesture('dragWindow'); });
document.querySelector('.topbar').addEventListener('dblclick', event => { if (titleBarGesture(event)) postTitleBarGesture('titleDoubleClick'); });
function run(promise) { Promise.resolve(promise).catch(error => { localError = error?.message || String(error); renderError(); }); }
document.addEventListener('click', event => {
  if (swallowClick) { swallowClick = false; return; }
  if (event.target.closest('#settings-content, #welcome, #support-dialog')) return;
  const control = event.target.closest('[data-action]');
  if (!control) {
    const tab = event.target.closest('.tabs [data-page]');
    if (tab) { run(send('navigate', { page: tab.dataset.page })); return; }
  }
  if (control && !control.disabled) {
    // An author link sits inside the control's label; don't also toggle that control.
    if (control.closest('label.property-label')) event.preventDefault();
    // Modifier clicks on installed tiles build a selection instead of changing the inspector.
    if (control.matches('.tile-select') && state?.page === 'installed' && (selecting || event.metaKey || event.ctrlKey || event.shiftKey)) { toggleSelection(control.dataset.id, { range: event.shiftKey }); return; }
    if (control.matches('.tile-select') && event.detail === 2 && state?.page === 'pixiv') { run(pixiv.doubleClick(control.dataset.id)); return; }
    // Apply on the second click instead of starting another selection request first.
    const action = control.matches('.tile-select') && event.detail === 2
      ? (state?.page === 'installed' ? 'activate' : tileDoubleClickAction(control.dataset.id)) : control.dataset.action;
    run(handleAction(action, control.dataset, control));
  }
  if (popover && !event.target.closest('#queue-popover, #import-popover, #history-popover') && !['openDownloads', 'openImport', 'openHistory'].includes(control?.dataset.action)) closePopover(false);
});
document.addEventListener('input', event => {
  const element = event.target;
  if (element.closest('#settings-content, #welcome')) return;
  if (collections.handleInput(element) || presets.handleInput(element) || placement.handleInput(element)) return;
  if (element.type === 'range') { const output = element.parentElement.querySelector('output'); if (output) output.textContent = element.dataset.setting === 'volume' || element.dataset.change === 'displayPosition' ? `${element.value}%` : element.value; }
  if (element.dataset.change === 'displayPosition') positionDrag.input(element);
  if (element.dataset.change === 'property') propertyDrag.input(element);
  if (element.dataset.input === 'property') { drafts.set(draftKey(element.dataset.id, element.dataset.propertyId), element.value); renderInspector(false); }
  if (element.dataset.input === 'account' && dialogAccount) { dialogAccount.account = element.value; renderDialog(); }
  if (element.dataset.input === 'pixivSearch' && state?.page === 'pixiv') pixiv.handleInput(element);
  if (element.dataset.input === 'search') {
    if (state.page === 'discover') {
      workshopDraft.text = element.value; clearTimeout(searchTimer);
      const text = element.value.trim();
      // A link pasted whole is looked up at once. A bare id (six digits or more, as the native
      // side reads one) waits for Return, or typing it would look up every prefix of it.
      if (/^(?:https?|steam):\/\/\S+$/i.test(text) && /^insertFrom(?:Paste|Drop)/.test(event.inputType || '')) run(searchWorkshop());
      else if (!/^\d{6,}$/.test(text)) searchTimer = setTimeout(() => run(searchWorkshop()), 450);
    } else { installed.text = element.value; renderGrid(false); viewState.touch(); }
  }
});
document.addEventListener('change', event => {
  const element = event.target;
  if (element.closest('#settings-content, #welcome')) return;
  const change = element.dataset.change;
  const value = element.type === 'checkbox' ? element.checked : element.type === 'number' || element.type === 'range' ? Number(element.value) : element.value;
  if (element.id === 'import-duplicates') { importDuplicates = value; renderPopover(); return; }
  if (change?.startsWith('pixiv')) { run(pixiv.handleChange(element)); return; }
  if (change?.startsWith('collection')) { run(collections.handleChange(element)); return; }
  if (change === 'presetPick') { presets.handleChange(element); return; }
  if (change === 'placement') { run(placement.handleChange(element)); return; }
  if (change === 'target') run(send('target', { id: value }));
  else if (change === 'property') run(commitProperty(element));
  else if (change === 'displayPosition') {
    // Only the moved axis is sent, so a horizontal drag never disturbs the vertical position.
    const axis = element.dataset.axis;
    if (axis === 'x' || axis === 'y') run(commitPosition(element.dataset.id, element.dataset.displayId, axis, value / 100));
  }
  else if (change === 'wallpaperSetting' || change === 'displayConfig') {
    if (element.validity && !element.validity.valid) { element.reportValidity(); return; }
    const args = { id: element.dataset.id, key: element.dataset.setting, value };
    if (change === 'wallpaperSetting' && args.key === 'volume') args.value = value / 100;
    if (change === 'displayConfig') args.displayID = element.dataset.displayId;
    run(send(change, args));
  } else if (change === 'sort') { if (state.page === 'discover') { workshopDraft.sort = value; run(searchWorkshop()); } else { installed.sort = value; installed.descending = installedSorts.find(([key]) => key === value)?.[2] ?? false; render(); } }
  else if (change === 'filterTag') { const draft = filterDraft(state.page === 'discover'); draft.tags = element.checked ? uniqueTags([...draft.tags, element.value]) : draft.tags.filter(tag => tag !== element.value); run(applyFilterChange()); }
  else if (change === 'filterExclude') { setExcluded(filterDraft(state.page === 'discover'), [element.value], !element.checked); run(applyFilterChange()); }
  else if (change === 'rememberSession' && dialogAccount) { dialogAccount.rememberSession = value; renderDialog(); }
});
document.addEventListener('submit', event => {
  const form = event.target;
  if (form.closest('#settings-content, #welcome')) return;
  event.preventDefault();
  if (form.dataset.form?.startsWith('pixiv') && state?.page === 'pixiv') { run(pixiv.handleSubmit(form)); return; }
  if (form.dataset.form === 'collectionName') { run(collections.handleSubmit(form)); return; }
  if (form.dataset.form === 'presetName') { run(presets.handleSubmit(form)); return; }
  if (form.dataset.form === 'search' && state.page === 'discover') run(searchWorkshop());
  if (form.dataset.form === 'workshopPage' && state.page === 'discover') {
    const input = form.elements.page;
    const pages = Math.min(workshopMaxPages(), Math.max(1, Number(state.workshop.totalPages) || 1));
    const page = Math.min(pages, Math.max(1, Math.round(Number(input.value)) || 1));
    input.value = String(page);
    if (page !== state.workshop.page && !state.workshop.loading) run(handleAction('workshopPage', { workshopPage: page }, input));
  }
  if (form.dataset.form === 'dialogContinue') run(continueDownload(false));
  if (form.dataset.form === 'dialogAuth') {
    const input = form.elements.response; const value = input.value;
    if (!value) return;
    // The secret belongs to this job alone and never survives the submit.
    input.value = '';
    run(sendDialog('downloadInput', { id: form.dataset.id, value }));
  }
});
document.addEventListener('keydown', event => {
  if (event.target.closest('#settings-content, #welcome, #support-dialog')) return;
  if (event.key === 'Escape') {
    endSweep();
    // An inline name field gives itself up first, as its own Cancel would.
    const editing = event.target.closest('form[data-cancel]');
    if (editing) { event.preventDefault(); run(handleAction(editing.dataset.cancel, {}, editing)); return; }
    if (popover) closePopover(true);
    else if ((selection.size || selecting) && !dialogTarget) { selection.clear(); selectionAnchor = null; selecting = false; render(); }
  }
  if (placement.handleKeydown(event)) return;
  if (['Delete', 'Backspace'].includes(event.key) && state?.page === 'installed' && !state.busy && event.target.closest('.wallpaper-tile')) {
    const id = event.target.closest('.wallpaper-tile')?.dataset.key;
    const ids = selection.size ? [...selection] : id ? [id] : [];
    if (ids.length) { event.preventDefault(); run(send('deleteMany', { ids })); }
  }
  if (event.key === 'Enter' && event.target.dataset.input === 'property') { event.preventDefault(); run(commitProperty(event.target)); }
  const tab = event.target.closest('.tabs [data-page], .source-tabs [data-source]');
  if (tab && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) { event.preventDefault(); const tabs = [...tab.parentElement.querySelectorAll('button')]; const index = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (tabs.indexOf(tab) + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length; tabs[index].focus(); }
  const tile = event.target.closest('.tile-select');
  if (tile && ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) {
    event.preventDefault();
    const tiles = [...$('wallpaper-grid').querySelectorAll('.tile-select')];
    const columns = getComputedStyle($('wallpaper-grid')).gridTemplateColumns.split(' ').length;
    const index = tiles.indexOf(tile);
    const offset = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -columns, ArrowDown: columns }[event.key];
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? tiles.length - 1 : Math.max(0, Math.min(tiles.length - 1, index + offset));
    tiles[next]?.focus();
  }
});
$('download-dialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog(); });
$('download-dialog').addEventListener('close', () => { if (dialogTarget !== null && !$('download-dialog').open) closeDialog(); });
window.addEventListener('resize', () => { if (popover) renderPopover(); queueLivePreviews(); placement.layout(); });
// A Discover page is one Steam page of 30 tiles, at most 1,000 pages deep. Nothing here measures
// the grid: CSS alone decides how many columns the tiles fill, and a page scrolls for the rest,
// so a window resize only reflows the tiles and never asks the native side for anything.
function workshopMaxPages() { return Math.max(1, Number(state?.workshop?.maxPages) || 1000); }
document.addEventListener('error', event => {
  const image = event.target;
  if (image.tagName !== 'IMG') return;
  // A cover the native cache could not make: the preview file itself stands in, once.
  if (image.dataset.fallback && image.getAttribute('src') !== image.dataset.fallback) { brokenCovers.add(image.getAttribute('src')); image.src = image.dataset.fallback; return; }
  image.classList.add('failed'); image.style.visibility = 'hidden';
  if (image.classList.contains('tile-live')) settleLivePreview(image, false); else if (image.classList.contains('tile-still')) queueLivePreviews();
}, true);
// Tiles pulse their placeholder until the image arrives, so a slow connection reads as loading, not broken.
document.addEventListener('load', event => { if (event.target.tagName !== 'IMG') return; event.target.classList.add('loaded'); if (event.target.classList.contains('tile-live')) settleLivePreview(event.target, true); else if (event.target.classList.contains('tile-still')) queueLivePreviews(); }, true);
// Discover tiles show their cached still at once. The animated preview then loads through
// mwe-ui://animated/<id> for tiles on screen whose still has arrived, six at a time in grid order
// (the still pass already left its bytes on disk, so this is a local read, not a download).
// Reveal on image load, never by drawing/reading pixels: WebKit's synchronous canvas IPC
// can stall the entire panel for repeated 15-second waits when its graphics backend hangs.
const live = new Map(); // id -> { status: 'queued' | 'loading' | 'ready' | 'failed', playing }
const LIVE_CONCURRENCY = 6;
let liveScrollTimer = null;
function tileOnScreen(tile) {
  const rect = tile.getBoundingClientRect(); const grid = $('wallpaper-grid').getBoundingClientRect();
  return rect.width > 0 && rect.bottom > grid.top && rect.top < grid.bottom;
}
function retireLivePreviews(ids) {
  for (const id of live.keys()) if (!ids.has(id)) {
    const image = $('wallpaper-grid').querySelector(`[data-key="live-${CSS.escape(id)}"]`);
    image?.closest('.wallpaper-tile')?.classList.remove('playing');
    image?.removeAttribute('src'); image?.remove(); live.delete(id);
  }
}
// Animations wait for the whole page of stills: every tile shows its picture before any tile
// spends bandwidth on motion, so a slow link reveals the page all at once rather than one
// animated tile at a time. A still counts as settled once it has loaded or failed.
function stillsSettled() {
  return [...$('wallpaper-grid').querySelectorAll('img.tile-still')].every(still => still.complete);
}
function queueLivePreviews() {
  if (state?.page === 'installed') { if (document.hidden) releaseLivePreviews(); return; }
  if (state?.page !== 'discover') return;
  const canLoad = !document.hidden && stillsSettled();
  let changed = false;
  for (const tile of $('wallpaper-grid').querySelectorAll('.tile-select')) {
    const id = tile.dataset.id;
    const entry = live.get(id);
    if (document.hidden || !tileOnScreen(tile)) {
      if (entry && ['loading', 'ready'].includes(entry.status)) {
        // Keep the disk cache and still, but release WebKit's animated image/decoder.
        tile.querySelector('img.tile-live')?.removeAttribute('src');
        entry.status = 'queued'; entry.playing = false; changed = true;
      }
      continue;
    }
    if (!canLoad || entry) continue;
    const item = (state.workshop?.items || []).find(each => each.id === id);
    const still = tile.querySelector('img.tile-still');
    if (!item || !safeImage(item.animated) || !item.thumbnail || !still?.complete || !still.naturalWidth) continue;
    live.set(id, { status: 'queued', playing: false });
  }
  pumpLivePreviews(changed);
}
function pumpLivePreviews(changed = false) {
  if (state?.page !== 'discover') return;
  if (!document.hidden && stillsSettled()) {
    let active = [...live.values()].filter(entry => entry.status === 'loading').length;
    for (const tile of $('wallpaper-grid').querySelectorAll('.tile-select')) {
      if (active >= LIVE_CONCURRENCY) break;
      const entry = live.get(tile.dataset.id);
      if (entry?.status !== 'queued' || !tileOnScreen(tile)) continue;
      entry.status = 'loading'; active += 1; changed = true;
    }
  }
  if (changed) renderGrid(true);
}
function settleLivePreview(image, loaded) {
  const id = image.closest('.tile-select')?.dataset.id;
  const entry = id ? live.get(id) : undefined;
  if (!entry || !['loading', 'ready'].includes(entry.status)) return;
  entry.playing = loaded && image.complete && image.naturalWidth > 0;
  entry.status = entry.playing ? 'ready' : 'failed';
  if (state?.page === 'discover') pumpLivePreviews(true); else renderGrid(false);
}
// Installed tiles hold still covers. The animation plays for one tile at a time: the one under the
// pointer or holding keyboard focus, and only after the pointer settles on it, so sweeping across
// the grid, dragging a selection or tabbing through it starts nothing. The preview file loads
// from disk only then; leaving the tile, hiding the page, a page change or a lost window focus
// releases it. A mouse click alone does not count as focus, so a selected tile does not keep playing.
const INSTALLED_LIVE_DELAY = 160;
let livePage = null;
let pointerLiveID = null;
let focusLiveID = null;
let installedLiveTimer = null;
function installedLiveTarget() {
  const id = pointerLiveID ?? focusLiveID;
  return id !== null && state?.page === 'installed' && !document.hidden ? id : null;
}
function installedLiveKeep(items) {
  for (const id of [pointerLiveID, focusLiveID]) if (id !== null && !items.some(item => item.id === id)) { if (id === pointerLiveID) pointerLiveID = null; if (id === focusLiveID) focusLiveID = null; }
  const id = installedLiveTarget();
  return id === null ? [] : [id];
}
// Drops every animation and forgets which tile was under the pointer or focused.
function releaseLivePreviews() {
  clearTimeout(installedLiveTimer);
  pointerLiveID = null; focusLiveID = null;
  retireLivePreviews(new Set());
}
function syncInstalledLive() {
  clearTimeout(installedLiveTimer);
  const id = installedLiveTarget();
  retireLivePreviews(new Set(id === null ? [] : [id]));
  if (id === null || live.has(id)) return;
  installedLiveTimer = setTimeout(() => {
    const item = installedLiveTarget() === id ? (state.wallpapers || []).find(each => each.id === id) : null;
    if (!item || !safeImage(item.animated)) return;
    live.set(id, { status: 'loading', playing: false });
    renderGrid(false);
  }, INSTALLED_LIVE_DELAY);
}
const liveTileID = (node) => node instanceof Element ? node.closest('.wallpaper-tile')?.dataset.key ?? null : null;
$('wallpaper-grid').addEventListener('pointerover', event => {
  const id = liveTileID(event.target);
  if (state?.page !== 'installed' || id === null || id === pointerLiveID || event.buttons) return;
  pointerLiveID = id; syncInstalledLive();
});
$('wallpaper-grid').addEventListener('pointerout', event => {
  const id = liveTileID(event.target);
  if (state?.page !== 'installed' || id === null || id !== pointerLiveID || liveTileID(event.relatedTarget) === id) return;
  pointerLiveID = null; syncInstalledLive();
});
$('wallpaper-grid').addEventListener('focusin', event => {
  const id = liveTileID(event.target);
  if (state?.page !== 'installed' || id === null || id === focusLiveID || !event.target.matches(':focus-visible')) return;
  focusLiveID = id; syncInstalledLive();
});
$('wallpaper-grid').addEventListener('focusout', event => {
  const id = liveTileID(event.target);
  if (state?.page !== 'installed' || id === null || id !== focusLiveID || liveTileID(event.relatedTarget) === id) return;
  focusLiveID = null; syncInstalledLive();
});
window.addEventListener('blur', () => { if (state?.page === 'installed') releaseLivePreviews(); });
$('wallpaper-grid').addEventListener('scroll', () => { clearTimeout(liveScrollTimer); liveScrollTimer = setTimeout(queueLivePreviews, 120); }, { passive: true });
document.addEventListener('visibilitychange', queueLivePreviews);
const welcomeInert = new Set();
function setWelcomeBackgroundInert(open) {
  for (const node of $('app').children) {
    if (node.tagName === 'DIALOG') continue;
    if (open && !node.inert) { node.inert = true; welcomeInert.add(node); }
    else if (!open && welcomeInert.delete(node)) node.inert = false;
  }
  supportPrompt.render(state);
}
// The first-run guide draws over the whole window, so it owns its own events and the panel's
// document-level handlers stay out of it.
const welcome = createWelcome({
  container: $('welcome'), send, run, escapeHTML, icon, button, morph, busy, safeLink, signInGuide, guideMarkup, stageHint,
  closePopover, setBackgroundInert: setWelcomeBackgroundInert, dragWindow: () => postTitleBarGesture('dragWindow'),
  clearError: () => { localError = ''; if (state) { state.error = null; state.downloadError = null; } renderError(); run(send('dismissError')); },
  navigate: (page) => send('navigate', { page }),
  openImport: async () => { await send('navigate', { page: 'installed' }); openPopover('import', document.querySelector('#browser-toolbar [data-action="openImport"]')); },
});
// The pixiv tab draws into the same library page, with the same helpers, as Discover.
const pixiv = createPixivPage({
  $, send, run, escapeHTML, icon, button, morph, keyAttr, checked, disabled, selectOptions, safeImage, safeLink, preview, tags, bytes, tileRing, filterButton, filterGroup, filterHeading,
  activate: (id) => handleAction('activate', { id }),
});
// Installed's collections, the inspector's presets, picture placement, compatibility card and
// black-bar card draw with the panel's helpers into the same page; each keeps only its own page state.
const collections = createCollections({ send, render, announce, escapeHTML, icon, button, keyAttr, checked, disabled, busy, filterGroup, selection, filtersCollapsed });
const presets = createPresets({ send, render, escapeHTML, icon, button, keyAttr, disabled, busy });
const placement = createPlacement({ send, render, escapeHTML, icon, button, keyAttr, disabled, busy, safeImage });
const compatibilityCard = createCompatibility({ escapeHTML, icon, button, keyAttr, busy, canReinstall });
const letterbox = createLetterbox({ escapeHTML, icon, button, keyAttr, busy });
placement.bind($('inspector'));
const supportPrompt = createSupportPrompt({
  container: $('support-dialog'), send, escapeHTML, icon, morph,
  canPresent: () => !welcome.isOpen() && !popover && dialogTarget === null && !state?.busy
    && !state?.applyingID && !(state?.queuedApplyIDs || []).length
    && !state?.pixiv?.account?.signingIn
    && !(state?.downloads || []).some(job => job.pending && (job.authenticating || job.prompt || job.challenge)),
  restoreFocus: (previous) => {
    if (welcome.isOpen() || document.querySelector('dialog[open]')) return;
    if (previous && previous !== document.body && previous !== document.documentElement
      && previous.isConnected && !previous.disabled && !previous.closest('[inert]') && previous.getClientRects().length) {
      previous.focus();
      if (document.activeElement === previous) return;
    }
    restorePanelFocus(['.tabs [aria-current="page"]']);
  },
});
applyStaticText();
run(send('ready'));
