import { t, language } from './i18n.js';
import { intervalLabel, unlockLabel, sourceSelect, sourceNote, planRows, plansGroup } from './plans.js';
import { backupGroup } from './backup.js';
import { playlistOrderMarkup, movePlaylistItem, installPlaylistDrag } from './playlist-order.js';
import { automationRows, solarLocationGroup, automationClick, automationInput, automationChange, automationSubmit, restoreAutomationFocus } from './automation.js';
import { displayTransferRow, displayLayoutsGroup, displayLayoutInput, displayLayoutChange, displayLayoutClick, displayLayoutSubmit } from './display-layouts.js';

const views = new WeakMap();
let liveView = null;
let pendingSection = null;
// Latest energy reading native pushed; it arrives every two seconds outside the snapshot.
let energyReading = null;
// Labels below are English source strings; every one is passed through t() where it is drawn.
const sections = [['performance', 'Performance', 'slidersVertical'], ['general', 'General', 'settings'], ['appearance', 'Appearance', 'sunMoon'], ['displays', 'Displays', 'monitor'], ['library', 'Library & Steam', 'folder'], ['storage', 'Storage', 'download'], ['about', 'About', 'info']];
// Shared with the welcome guide's Performance page; WebPanelActions.applyQualityPreset holds the same values.
export const qualityPresets = { low: { frameRateCap: 30, renderScale: 0.5 }, medium: { frameRateCap: 60, renderScale: 0.75 }, high: { frameRateCap: null, renderScale: 1 } };
export const qualityPresetLabels = [['low', 'Low'], ['medium', 'Medium'], ['high', 'High']];
const batteryModes = [['keepRunning', 'Keep running'], ['reducedQuality', 'Reduced quality'], ['pause', 'Pause']];
const otherAudioActions = [['keepRunning', 'Keep running'], ['mute', 'Mute'], ['pause', 'Pause']];
const displaySleepActions = [['pause', 'Pause'], ['stop', 'Stop (free memory)']];
const desktopCoveredActions = [['pause', 'Pause'], ['keepRunning', 'Keep running']];
// Reduced quality keeps wallpapers playing at the battery profile's scale and frame rate instead of
// pausing them. Low Power Mode, a hot Mac and a low battery offer it; display sleep and the rest do not.
const systemConditionActions = [['keepRunning', 'Keep running'], ['reduceQuality', 'Reduced quality'], ['pause', 'Pause'], ['stop', 'Stop (free memory)']];
// The charge levels the low-battery rule offers, in percent; Swift refuses any other.
const lowBatteryLevels = [[10, '10%'], [20, '20%'], [30, '30%']];
const focusActions = { keepRunning: 'Keep running', mute: 'Mute', pause: 'Pause', stop: 'Stop (free memory)', wallpaper: 'Use wallpaper', playlist: 'Use saved playlist' };
const thermalStates = { nominal: 'normal', fair: 'warm', serious: 'hot', critical: 'very hot' };
const hotkeyTitles = { togglePlayback: 'Play or pause wallpapers', toggleMute: 'Mute or unmute wallpapers', nextWallpaper: 'Next wallpaper', previousWallpaper: 'Previous wallpaper', randomWallpaper: 'Random wallpaper', openControlPanel: 'Open the control panel' };
// What the Shortcuts app and wallpapermachine:// links can do; the ellipsis stands for an id.
const automationLinks = ['wallpapermachine://toggle', 'wallpapermachine://play', 'wallpapermachine://pause', 'wallpapermachine://mute', 'wallpapermachine://unmute', 'wallpapermachine://togglemute', 'wallpapermachine://next', 'wallpapermachine://previous', 'wallpapermachine://random', 'wallpapermachine://random?from=favorites', 'wallpapermachine://apply?id=…', 'wallpapermachine://apply?id=…&display=all', 'wallpapermachine://playlist?id=…', 'wallpapermachine://preset?id=…', 'wallpapermachine://layout?id=…', 'wallpapermachine://open?page=settings'];
const playlistModes = [['off', 'Off'], ['rotate', 'Rotate wallpapers'], ['dayNight', 'Day and night']];
const playlistOrders = [['sequential', 'In order'], ['shuffle', 'Shuffle']];
// Draft keys of a display's How often menu and its custom minutes field.
const intervalKeys = displayID => ({ menu: `display-${displayID}-playlist-interval`, field: `display-${displayID}-playlist-custom-interval` });

// A minute of the day as an <input type="time"> value, and back.
const clockValue = (minute) => `${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}`;
function clockMinute(value) {
  const match = /^(\d{2}):(\d{2})$/.exec(String(value));
  if (!match) return null;
  const minute = Number(match[1]) * 60 + Number(match[2]);
  return minute >= 0 && minute < 1440 ? minute : null;
}

// When a playlist changes next: the time alone today, with the weekday otherwise.
function changeTime(milliseconds) {
  const date = new Date(milliseconds);
  const today = new Date().toDateString() === date.toDateString();
  return date.toLocaleString(language(), today ? { hour: 'numeric', minute: '2-digit' } : { weekday: 'short', hour: 'numeric', minute: '2-digit' });
}
const appRuleConditions = [['running', 'Running'], ['frontmost', 'In front']];
const appRuleActions = [['pause', 'Pause'], ['mute', 'Mute'], ['stop', 'Stop']];
const compactNavigation = window.matchMedia('(max-width: 560px)');
const renderScales = [[1, '100% (native)'], [0.75, '75%'], [0.5, '50%']];
const videoBackends = [['compatibility', 'Compatibility'], ['native_preferred', 'Native video preferred']];
const sceneRenderers = [['compatibility', 'Compatibility'], ['native_metal_preferred', 'Native Metal preferred']];
// How a scene's video textures reached the shaders sampling them, as the
// renderer reported it. `none` is deliberately absent: a scene with no video
// has nothing to say, and naming it would read as a failure.
const videoPaths = {
  bgra: 'sampled directly, no conversion',
  nv12_direct: 'planes sampled directly, no conversion',
  nv12_converted: 'converted once per frame',
  nv12_mixed: 'planes sampled directly, plus one shared conversion',
  nv12_converted_preparing: 'converted once per frame, direct sampling still being prepared',
};
// The renderer's own words for why a scene is still updating. `unknown_input`
// is deliberately not folded into a generic phrase: it means the renderer found
// an input it could not account for and kept the scene running, which is the
// whole diagnosis when on-demand appears to do nothing.
const demandReasons = {
  script: 'a script', animation: 'animation', particles: 'particles', video: 'video',
  audio_response: 'audio response', time_uniform: 'a time-based effect',
  animated_sprite: 'an animated sprite', dynamic_mesh: 'a dynamic mesh', puppet: 'a puppet',
  feedback: 'a feedback pass', text_binding: 'bound text', sound: 'sound',
  node_binding: 'a bound node', unknown_input: 'an input the renderer could not account for',
  text_layout_pending: 'text still being laid out',
};
// Every mode the bridge can emit. `unknown` is a running scene that could not be
// read, which is not the same as one that is ticking, so it gets its own words.
// `stopped_after_failure` is a scene whose renderer gave up after an error: it is
// not paused by anyone, so it must never be worded like a pause.
const sceneModes = {
  continuous: 'updating continuously', waiting_for_event: 'waiting for events',
  waiting_for_deadline: 'waiting for a timer', user_paused: 'paused by you',
  policy_suspended: 'suspended by the app', stopped_after_failure: 'stopped after a rendering failure',
  not_applicable: 'not applicable to this wallpaper',
  unknown: 'running — state could not be read',
};
// Only backends that actually drew something are named here. A scene with no
// backend yet is a phase of its own and is worded separately below.
const sceneBackends = { legacy_vulkan: 'Compatibility', native_metal: 'Native Metal' };

// Reports the scale the engine actually published. Quantizing here would let a
// value the control cannot offer be shown as one that it can.
function percent(value) {
  const number = Number(value);
  return Number.isFinite(number) ? `${Math.round(number * 100)}%` : t('Unavailable');
}

// A hand-edited config may hold a scale between the offered tiers. Carry it as its
// own option so the control shows the saved value instead of snapping the display
// to a neighbouring tier the user never chose.
function scaleOptions(value) {
  const number = Number(value);
  const scales = renderScales.map(([step, label]) => [step, t(label)]);
  if (!Number.isFinite(number) || renderScales.some(([step]) => step === number)) return scales;
  return [[number, t('{percent} (from configuration)', { percent: percent(number) })], ...scales];
}
const localizedOptions = (entries) => entries.map(([id, label]) => [id, t(label)]);

function scaleValue(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : renderScales[0][0];
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function storedFrameRateCap(settings) {
  if (settings.frameRateCap == null || settings.frameRateCap === '') return null;
  return finiteNumber(settings.frameRateCap);
}

function frameRateCapMax(settings) {
  const max = finiteNumber(settings.frameRateCapMax);
  return max != null && max >= 10 ? Math.round(max) : 60;
}

// The slider runs to one step past the highest display refresh: every rate up to
// that refresh is a choosable cap, and the extra top position is no limit, which
// leaves every display at its own frame rate. A stored cap above the refresh is
// shown as that refresh.
export function frameRateCapSlider(settings) {
  const refresh = frameRateCapMax(settings);
  const max = refresh + 1;
  const cap = storedFrameRateCap(settings);
  const unlimited = cap == null;
  return { max, unlimited, value: unlimited ? max : Math.min(refresh, Math.max(10, Math.round(cap))) };
}

// The slider's value: the top of its range is sent as null (no limit).
export function frameRateCapValue(value, max) {
  const number = Number(value);
  return number >= Number(max) ? null : Math.round(number);
}

export function frameRateCapReadout(value, max) {
  const number = finiteNumber(value);
  if (number == null || number >= Number(max)) return t('No limit');
  return t('{fps} fps', { fps: Math.round(number) });
}

export function activeQualityPreset(settings) {
  const scale = finiteNumber(settings.preferredRenderScale);
  const cap = storedFrameRateCap(settings);
  for (const [id, preset] of Object.entries(qualityPresets)) {
    const capMatches = preset.frameRateCap == null ? cap == null : cap === preset.frameRateCap;
    const scaleMatches = scale != null && Math.abs(scale - preset.renderScale) < 0.001;
    if (capMatches && scaleMatches) return id;
  }
  return 'custom';
}

// Effective rate for the "limited by Performance" note: the saved fps against the
// ceiling the engine reports in force, which is the global cap lowered by the
// reduced-quality frame rate while that holds, whatever the reason. Display refresh
// is not a Performance setting, so it does not raise this note.
export function performanceLimitedFps(saved, settings = {}) {
  const rate = finiteNumber(saved);
  if (rate == null) return null;
  const ceiling = settings.effectiveFrameRateCap == null ? null : finiteNumber(settings.effectiveFrameRateCap);
  return ceiling != null && ceiling < rate ? ceiling : null;
}

// Why quality is lowered right now, most specific first: the reasons the engine
// holds (heat, Low Power Mode, a low battery), then the battery mode, which the
// engine reports as the power source rather than as a reason.
const qualityCauseOrder = ['heat', 'lowPowerMode', 'lowBattery'];
function qualityReducedBy(settings) {
  const held = Array.isArray(settings.qualityThrottle) ? settings.qualityThrottle : [];
  const causes = qualityCauseOrder.filter(cause => held.includes(cause));
  if (settings.batteryMode === 'reducedQuality' && settings.onBatteryPower) causes.push('battery');
  return causes;
}

// The sentences name the first cause only; every one is a direct t() call so the
// localization check sees it.
function qualityStatusText(cause) {
  switch (cause) {
    case 'heat': return t('The Mac is hot. Reduced quality is in use.');
    case 'lowPowerMode': return t('Low Power Mode is on. Reduced quality is in use.');
    case 'lowBattery': return t('The battery is low. Reduced quality is in use.');
    case 'battery': return t('On battery. Reduced quality is in use.');
    default: return t('Your usual quality settings are in use.');
  }
}

function qualityEffectiveText(cause, values) {
  switch (cause) {
    case 'heat': return t('{effective} while the Mac is hot. Your setting is {saved}.', values);
    case 'lowPowerMode': return t('{effective} in Low Power Mode. Your setting is {saved}.', values);
    case 'lowBattery': return t('{effective} while the battery is low. Your setting is {saved}.', values);
    case 'battery': return t('{effective} on battery. Your setting is {saved}.', values);
    default: return t('{effective}. Your setting of {saved} is not in effect right now.', values);
  }
}

export function revealSettingsSection(section) {
  if (!sections.some(([id]) => id === section)) return;
  pendingSection = section;
  if (!liveView) return;
  liveView.section = section;
  if (liveView.container.isConnected) draw(liveView);
}

export function milliwatts(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return t('Unavailable');
  if (number >= 1000) return t('{value} W', { value: (number / 1000).toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 }) });
  return t('{value} mW', { value: Math.round(number).toLocaleString() });
}

// Thresholds live in Swift (EnergyLevel); the page only names the grade it was sent.
const energyLevels = { low: 'Low energy use', medium: 'Medium energy use', high: 'High energy use' };
export function energyLevelLabel(level) {
  return energyLevels[level] ? t(energyLevels[level]) : '';
}

export function batteryShare(percent) {
  const number = Number(percent);
  if (!Number.isFinite(number)) return '';
  if (number < 1) return t('Less than 1% of a full battery charge per hour.');
  return t('About {percent}% of a full battery charge per hour.', { percent: Math.round(number) });
}

// Native keeps the last settled reading from before a rendering setting changed and
// fills in the after figure once a full window has passed under the new setting.
function comparisonNote(comparison) {
  if (!comparison || !Number.isFinite(Number(comparison.beforeMilliwatts))) return '';
  const before = Number(comparison.beforeMilliwatts);
  if (!Number.isFinite(Number(comparison.afterMilliwatts))) return t('Measuring the effect of your change. Before it: {before}.', { before: milliwatts(before) });
  const after = Number(comparison.afterMilliwatts);
  const change = before > 0 ? Math.round((after - before) / before * 100) : null;
  if (change == null || change === 0) return t('Before your change: {before}. Now: {after}, about the same.', { before: milliwatts(before), after: milliwatts(after) });
  return t('Before your change: {before}. Now: {after} ({change}).', { before: milliwatts(before), after: milliwatts(after), change: `${change > 0 ? '+' : '−'}${Math.abs(change)}%` });
}

// No role="status": a readout that changes every two seconds must not be announced each time.
function energyControl(escapeHTML) {
  const reading = energyReading || { status: 'measuring' };
  const note = (key, text, style = '') => text ? `<span class="settings-note ${style}" data-key="${key}">${escapeHTML(text)}</span>` : '';
  const status = text => `<span class="settings-energy-state" data-key="energy-state">${escapeHTML(text)}</span>`;
  if (reading.status === 'unavailable') return status(t('Unavailable on this Mac'));
  const comparison = note('energy-comparison', comparisonNote(reading.comparison), 'settings-energy-comparison');
  if (reading.status !== 'ready') return `${status(t('Measuring…'))}${comparison}`;
  const figures = `<dl class="settings-energy-breakdown"><div><dt>${escapeHTML(t('CPU'))}</dt><dd>${escapeHTML(milliwatts(reading.cpuMilliwatts))}</dd></div><div><dt>${escapeHTML(t('GPU'))}</dt><dd>${escapeHTML(milliwatts(reading.gpuMilliwatts))}</dd></div></dl>`;
  // A qualified window has no grade. Native video is decoded and drawn by macOS outside
  // this app's accounting; a contended GPU figure includes other apps' clock.
  const flags = [
    [reading.nativeVideo, t('Native video not counted'), 'energy-native-video', t('macOS decodes and draws videos played with Native video and charges none of that to this app, so these figures leave most of it out. The grade and any comparison are off while one plays.')],
    [reading.gpuContended, t('GPU shared with other apps'), 'energy-contention', t('Other apps are keeping the GPU busy, so the GPU figure reads higher than this app’s own share. The grade and any comparison wait until the GPU is free.')],
  ].filter(([on]) => on);
  if (flags.length) return `<div class="settings-energy-overview" data-key="energy-overview">${status(flags[0][1])}${figures}</div>${flags.map(([, , key, text]) => note(key, text)).join('')}${comparison}`;
  const total = Number(reading.cpuMilliwatts) + Number(reading.gpuMilliwatts);
  const level = energyLevelLabel(reading.level);
  return `<div class="settings-energy-overview" data-key="energy-overview"><div class="settings-energy-total"><span class="settings-energy-power">${escapeHTML(milliwatts(total))}</span>${level ? `<span class="settings-energy-level" data-level="${escapeHTML(reading.level)}">${escapeHTML(level)}</span>` : ''}</div>${figures}</div>${note('energy-battery', batteryShare(reading.batteryPercentPerHour))}${comparison}`;
}

export function showEnergyUsage(reading) {
  if (!reading || typeof reading !== 'object') return;
  energyReading = reading;
  const control = liveView?.container.isConnected ? liveView.container.querySelector('[data-key="energy-use"] .settings-control') : null;
  if (!control) return;
  const template = document.createElement('template');
  template.innerHTML = energyControl(liveView.helpers.escapeHTML);
  reconcile(control, template.content);
}


export function renderSettings(container, state, helpers) {
  let view = views.get(container);
  if (!view) {
    // `editor` is an inline name field in use (a saved playlist being named or renamed) and
    // `armed` a Delete that has been pressed once and waits for its confirmation.
    view = { container, state, helpers, section: 'performance', settingsSectionToken: NaN, drafts: new Map(), pending: new Set(), error: '', recording: null, editor: null, armed: '' };
    views.set(container, view);
    installPlaylistDrag(view, (displayID, ids, expectedIDs, id) => submitPlaylistOrder(view, displayID, ids, expectedIDs, id));
    container.addEventListener('click', event => onClick(view, event));
    container.addEventListener('input', event => onInput(view, event));
    container.addEventListener('change', event => onChange(view, event));
    container.addEventListener('submit', event => onSubmit(view, event));
    container.addEventListener('focusout', event => onFocusOut(view, event));
    // Escape in an inline name field gives the field up, as its Cancel does.
    container.addEventListener('keydown', event => {
      if (event.key === 'Escape' && view.layoutEditor && !view.pending.has('display-layout') && event.target.closest('[data-form="display-layout"]')) {
        event.preventDefault(); displayLayoutClick(view, 'layoutCancel', {}, () => draw(view)); return;
      }
      if (event.key !== 'Escape' || !view.editor || !event.target.closest('form[data-form="name"]')) return;
      event.preventDefault();
      endEditing(view);
      draw(view);
    });
    compactNavigation.addEventListener('change', () => draw(view));
    // Recording a keyboard shortcut takes the next key press made in its row, before anything
    // else reads it; pressing Escape alone, or moving focus away, gives up.
    container.addEventListener('keydown', event => {
      if (!view.recording) return;
      if (!event.target.closest(`[data-key="hotkey-${view.recording}"]`)) { view.recording = null; draw(view); return; }
      if (['Meta', 'Control', 'Alt', 'Shift', 'CapsLock', 'Fn', 'FnLock'].includes(event.key)) return;
      event.preventDefault();
      event.stopPropagation();
      const id = view.recording;
      view.recording = null;
      if (event.key === 'Escape' && !event.metaKey && !event.ctrlKey && !event.altKey) { draw(view); return; }
      perform(view, `hotkey-${id}`, 'hotkeySet', { id, code: event.code, command: event.metaKey, option: event.altKey, control: event.ctrlKey, shift: event.shiftKey });
    }, true);
    container.addEventListener('keydown', event => {
      const target = event.target.closest('[data-section]');
      const previous = compactNavigation.matches ? 'ArrowLeft' : 'ArrowUp';
      const nextKey = compactNavigation.matches ? 'ArrowRight' : 'ArrowDown';
      if (!target || ![previous, nextKey, 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      const index = sections.findIndex(([id]) => id === view.section);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? sections.length - 1 : (index + (event.key === nextKey ? 1 : -1) + sections.length) % sections.length;
      view.section = sections[next][0];
      draw(view);
      container.querySelector('.settings-scroll').scrollTop = 0;
      container.querySelector(`[data-section="${view.section}"]`).focus();
    });
  }
  view.state = state;
  view.helpers = helpers;
  const token = Number(state.settingsSectionToken);
  if (Number.isFinite(token) && token !== view.settingsSectionToken) {
    view.settingsSectionToken = token;
    if (sections.some(([id]) => id === state.settingsSection)) view.section = state.settingsSection;
  }
  if (pendingSection && sections.some(([id]) => id === pendingSection)) {
    view.section = pendingSection;
    pendingSection = null;
  }
  liveView = view;
  // Prerequisites, sign-in and Steam Guard live only in the panel's focused download dialog.
  draw(view);
}

function draw(view) {
  const { state, helpers, drafts } = view;
  const e = value => helpers.escapeHTML(String(value ?? ''));
  const settings = state.settings || {};
  const setup = state.setup || {};
  const downloads = state.downloads || [];
  const scene = downloads.find(download => download.id === 'scene-assets');
  const anyDownload = downloads.some(download => download.pending);
  const busy = Boolean(state.busy || view.pending.size);
  const unavailable = !state.settings;
  const disabled = value => value ? ' disabled' : '';
  const draft = (key, fallback) => drafts.has(key) ? drafts.get(key) : fallback;
  const attrs = (action, args = {}) => `data-action="${e(action)}" data-args="${e(JSON.stringify(args))}"`;
  const button = (label, action, args = {}, off = false, style = '') => `<button type="button" class="settings-button ${style}" ${attrs(action, args)}${disabled(off)}>${e(label)}</button>`;
  const row = (key, label, control, note = '', style = '', controlKey = '') => `<div class="settings-row${style ? ` ${style}` : ''}" data-key="${e(key)}"><${controlKey ? `label for="settings-control-${e(controlKey)}"` : 'div'} class="settings-label">${e(label)}${note ? `<span class="settings-note" id="settings-note-${e(key)}">${e(note)}</span>` : ''}</${controlKey ? 'label' : 'div'}><div class="settings-control">${control}</div></div>`;
  const toggle = (key, label, checked, data, off = false) => `<label class="settings-switch"><input id="settings-control-${e(key)}" data-key="${e(key)}" type="checkbox" role="switch" aria-label="${e(label)}" ${data}${checked ? ' checked' : ''}${disabled(off)}><span aria-hidden="true"></span></label>`;
  const select = (key, label, value, options, data, off = false) => `<select data-key="${e(key)}" aria-label="${e(label)}" ${data}${disabled(off)}>${options.map(([id, title]) => `<option value="${e(id)}"${String(value ?? '') === String(id) ? ' selected' : ''}>${e(title)}</option>`).join('')}</select>`;
  const error = (key, message) => message ? `<div class="settings-error" role="alert" data-key="${key}">${e(message)}</div>` : '';
  const disclosure = (key, title, content, style = '', note = '') => `<details class="settings-disclosure${style ? ` ${style}` : ''}" data-key="${e(key)}"><summary><span class="settings-disclosure-indicator" aria-hidden="true">${helpers.icon('chevronRight', 16)}</span><span class="settings-disclosure-title">${e(title)}${note ? `<span class="settings-note">${e(note)}</span>` : ''}</span></summary><div class="settings-disclosure-body">${content}</div></details>`;
  const group = (key, title, content) => `<section class="settings-group" data-key="${e(key)}"${title ? ` aria-labelledby="settings-group-${e(key)}"` : ''}>${title ? `<h3 id="settings-group-${e(key)}">${e(title)}</h3>` : ''}${content}</section>`;
  const section = (id, title, content, action = '') => `<section class="settings-page" id="settings-${id}" role="tabpanel" aria-labelledby="settings-tab-${id}" tabindex="0" data-key="page-${id}"${view.section === id ? '' : ' hidden'}><header class="settings-heading"><h2>${e(title)}</h2>${action}</header>${content}</section>`;
  const settingToggle = (key, label, off = false, note = '', extra = '') => row(key, t(label), toggle(key, t(label), draft(key, settings[key]), `data-setting="${key}"${note ? ` aria-describedby="settings-note-${key}"` : ''}`, off || busy || unavailable) + extra, note, '', key);
  // The login item is registered but switched off in System Settings; only the user can allow it there.
  const loginNote = !settings.launchAtLoginAvailable ? t('Move the app to Applications to enable.')
    : settings.launchAtLoginNeedsApproval ? t('Allow WallpaperMachine in System Settings → General → Login Items to launch it at login.') : '';
  const loginAction = settings.launchAtLoginAvailable && settings.launchAtLoginNeedsApproval ? button(t('Open Login Items…'), 'openLoginItemsSettings', {}, busy) : '';
  const paragraphs = (...texts) => texts.map(text => `<p>${e(text)}</p>`).join('');
  // The helpers the saved-playlist and backup modules draw with, so their rows match these.
  const ctx = { state, view, e, row, select, button, toggle, group, disclosure, error, draft, busy, unavailable };
  const lockUnavailable = unavailable || settings.lockScreenAvailable === false || settings.lockScreenStatus == null;
  const screenSaverUnavailable = unavailable || settings.screenSaverAvailable === false || settings.screenSaverStatus == null;
  // Language lives natively beside the theme, so it stays usable when renderer settings are unavailable.
  // Option names are each language's own name and are deliberately left untranslated.
  const languageState = state.language || {};
  const languageOptions = [['system', t('System (Auto)')], ...(languageState.options || []).map(option => [option.id, option.name])];
  const languageValue = draft('language', languageState.preference || 'system');
  const general = group('general-language', t('Interface'), row('language', t('Language'), select('language', t('Language'), languageValue, languageOptions, 'data-language-setting', view.pending.has('language')), t('The interface and import picker switch at once. Quit and reopen the app to switch menus and other dialogs.')))
    + group('general-behavior', t('Startup & desktop'), settingToggle('launchAtLogin', 'Launch at login', !settings.launchAtLoginAvailable, loginNote, loginAction)
      + settingToggle('hideAfterActivating', 'Hide window after applying a wallpaper')
      + settingToggle('livePropertyEdits', 'Show property edits on the desktop as I make them', false, t('While you edit a wallpaper’s properties, your displays follow each change before you press Apply changes, and Revert puts the saved look back. Pictures and options that switch an effect on or off still wait for Apply changes. The lock screen and the Mission Control picture keep the saved look until you apply.'))
      + settingToggle('keepWindowsOnWallpaperClick', 'Keep windows in place when clicking the wallpaper', false, t('Turns off macOS’s “Click wallpaper to reveal desktop” so clicks reach interactive wallpapers.'))
      + settingToggle('writeDesktopPicture', 'Use the wallpaper as the macOS desktop picture', settings.desktopPictureLocked === true, settings.desktopPictureLocked === true ? t('Animate lock screen sets the desktop picture itself, so this cannot be changed while it is on.') : t('Mission Control and the moment before a wallpaper loads show a still frame of the wallpaper. Turn this off to leave macOS’s own wallpaper settings alone; your own picture comes back at once.'))
      + settingToggle('refreshDesktopPicture', 'Update the Mission Control picture every 5 minutes', settings.writeDesktopPicture === false, t('Mission Control shows a still picture of the wallpaper, retaken when it starts, changes or resumes. This also retakes it while it plays. Not used while the lock screen is animated.')))
    + group('general-shortcuts', t('Keyboard shortcuts'), (settings.hotkeys || []).map(hotkey => {
      const id = String(hotkey.id);
      const recording = view.recording === id;
      const control = recording
        ? `<span class="settings-status" role="status">${e(t('Press the new shortcut…'))}</span>${button(t('Cancel'), 'hotkeyCancel', { id })}`
        : `<kbd class="settings-shortcut">${e(hotkey.shortcut || t('Not set'))}</kbd>${button(hotkey.shortcut ? t('Change…') : t('Record…'), 'hotkeyRecord', { id }, busy)}${hotkey.shortcut ? button(t('Clear'), 'hotkeyClear', { id }, busy) : ''}`;
      return row(`hotkey-${id}`, t(hotkeyTitles[id] || id), control) + error(`hotkey-error-${id}`, hotkey.error);
    }).join('') + `<p class="settings-note" data-key="hotkeys-note">${e(t('They work whichever app is in front. Hold ⌘, ⌥ or ⌃ with the key; F13 to F20 work alone. No permission is needed.'))}</p>`)
      + disclosure('general-automation', t('Shortcuts app and links'), paragraphs(t('The Shortcuts app can control playback, mute or unmute wallpapers, go to the previous or next wallpaper, apply a wallpaper, saved playlist or property preset, and open this window. Siri and Spotlight can run these actions too.'), t('Apply Display Layout restores a saved arrangement across its displays. Choose the layout by name in Shortcuts, or use its saved id in a layout link.'), t('Random Wallpaper changes a display to a wallpaper other than the one it shows, and goes through all of them before it repeats one. It can draw from your favorites only: choose Favorites in Shortcuts, or use from=favorites in a link.'), t('Links can run the same actions. Wallpaper and playlist actions accept display= for a specific screen; otherwise they use the target display. An apply link also accepts display=all, and Apply Wallpaper has an On all displays option, to use every display at once. Property presets affect their wallpaper on every display. Choose saved items by name in Shortcuts.')) + `<ul class="settings-list" data-key="automation-links">${automationLinks.map(link => `<li><code>${e(link)}</code></li>`).join('')}</ul>`)
    + group('general-lock', t('Lock screen'), settingToggle('lockScreenEnabled', 'Animate lock screen', lockUnavailable || settings.lockScreenBusy, t('Experimental'))
      + row('lock-status', t('Lock screen status'), `<span class="settings-status" role="status">${e(lockUnavailable ? (settings.lockScreenAvailable === false && settings.lockScreenStatus) || t('Unavailable') : settings.lockScreenBusy ? `${settings.lockScreenStatus || t('Updating')}…` : settings.lockScreenStatus)}</span>${settings.lockScreenError ? button(t('Retry'), 'lockScreenRetry', {}, busy || settings.lockScreenBusy) : ''}`, '', 'settings-readout')
      + error('lock-error', settings.lockScreenError)
      + disclosure('lock-context', t('Compatibility & permissions'), paragraphs(t('Lock screen animation uses private macOS APIs and may stop working after a macOS update. While it is on, the app takes over only the Desktop wallpaper selection on displays with an applied scene or video wallpaper, and reloads the macOS wallpaper service. The screen saver is a separate choice below. Turning this off restores the Desktop choices; quitting restores all choices the app changed and keeps other wallpaper changes.'), t('It keeps separate copies of wallpaper files, which uses extra disk space, and may not render on every macOS version. Pause and battery settings still apply.'))))
    + group('general-screen-saver', t('Screen saver'), settingToggle('screenSaverEnabled', 'Use wallpaper as screen saver', screenSaverUnavailable || settings.screenSaverBusy, t('Experimental'))
      + row('screen-saver-status', t('Screen saver status'), `<span class="settings-status" role="status">${e(screenSaverUnavailable ? (settings.screenSaverAvailable === false && settings.screenSaverStatus) || t('Unavailable') : settings.screenSaverStatus || t('Updating'))}</span>${settings.screenSaverError ? button(t('Retry'), 'screenSaverRetry', {}, busy || settings.screenSaverBusy || screenSaverUnavailable) : ''}`, '', 'settings-readout')
      + error('screen-saver-error', settings.screenSaverError)
      + disclosure('screen-saver-context', t('Compatibility & permissions'), paragraphs(t('Requires macOS 26 or later. Uses each display’s applied wallpaper as its screen saver, including scenes, videos, web wallpapers and still images. This experimental feature uses private macOS APIs and may stop working after an update.'), t('The screen saver choice is independent of lock screen animation. It changes only the Idle wallpaper selection and reloads the macOS wallpaper service. Turning it off restores the previous screen saver without changing the Desktop selection, and keeps screen saver changes made elsewhere. Pause and battery settings still apply.'))));

  const scaleSupported = settings.renderScaleSupported !== false;
  // Compare what the engine published, not the quantized select step: leaving
  // reduced quality restores the saved scale on that same snapshot, and the
  // override notice has to disappear with it.
  const scaleOverridden = Number(settings.renderScale) !== Number(settings.preferredRenderScale);
  const preferredScale = scaleValue(settings.preferredRenderScale);
  const batteryScale = scaleValue(settings.batteryRenderScale);
  // The render scale and frame rate below are one profile, shared by every Reduced quality choice.
  // A low-battery choice counts only on a Mac with a battery, which is where its select is offered.
  const reducedChosen = settings.batteryMode === 'reducedQuality' || settings.lowPowerModeAction === 'reduceQuality'
    || settings.thermalAction === 'reduceQuality' || (settings.batteryPercent != null && settings.lowBatteryAction === 'reduceQuality');
  const reducedBy = qualityReducedBy(settings);
  const sessions = Number(settings.sharedVideoDecodeSessions) || 0;
  const consumers = Number(settings.sharedVideoDecodeConsumers) || 0;
  const displayName = (name, id) => name || t('Display {id}', { id });
  const backendLine = report => `${displayName(report.displayName, report.displayId)} — ${report.wallpaperTitle || report.wallpaperId}: ${report.backend}${report.fallbackReason ? ` ${t('(fallback: {reason})', { reason: report.fallbackReason })}` : ''}`;
  const backendReport = (settings.videoBackends || []).map(report => `<li>${e(backendLine(report))}</li>`).join('');
  // `no_frame_yet` is not a content reason — the scene simply has not finished a
  // first frame — so it is reported as starting rather than listed as a cause.
  const sceneModeLine = report => {
    const where = `${displayName(report.display, report.displayId)} — ${report.wallpaperTitle || report.wallpaperId || t('wallpaper')}`;
    // Before the starting check: a scene whose first frame failed also has no
    // frame yet, and reading "starting" forever is the lie this mode exists to end.
    // The reasons describe what keeps a clock running, which is moot once it stopped.
    if (report.mode === 'stopped_after_failure') return `${where}: ${t(sceneModes.stopped_after_failure)}`;
    const reasons = Array.isArray(report.reasons) ? report.reasons : [];
    if (reasons.includes('no_frame_yet')) return `${where}: ${t('starting — no frame drawn yet')}`;
    const named = reasons.map(reason => t(demandReasons[reason]) || reason);
    const mode = t(sceneModes[report.mode]) || t('state reported as {mode}', { mode: report.mode });
    return `${where}: ${mode}${named.length ? ` (${named.join(', ')})` : ''}`;
  };
  // Three separate facts, none of them the saved preference. No backend has been
  // reported yet means the scene is still being read and no backend has been
  // chosen — not that one was chosen and could not be named. A scene drawn by
  // Compatibility while Native Metal was preferred fell back, and the renderer's
  // own reason is shown when it supplied one; an absent reason is left absent
  // rather than filled in with a guess.
  const sceneRendererLine = report => {
    const where = `${displayName(report.display, report.displayId)} — ${report.wallpaperTitle || report.wallpaperId || t('wallpaper')}`;
    if (!report.backend || report.backend === 'unknown') return `${where}: ${t('preparing — no backend chosen yet')}`;
    // A name this build does not know is still a backend that drew the scene,
    // so it is reported verbatim instead of being folded into preparing.
    const backend = t(sceneBackends[report.backend]) || report.backend;
    const fellBack = report.backend === 'legacy_vulkan' && settings.sceneRenderer === 'native_metal_preferred';
    // Only ever named when the renderer observed one: a scene with no video,
    // or one that has not drawn yet, reports `none` and says nothing here.
    const video = t(videoPaths[report.videoPath]);
    return `${where}: ${backend}${fellBack && report.fallbackReason ? ` ${t('(fell back: {reason})', { reason: report.fallbackReason })}` : ''}${video ? ` ${t('— video: {path}', { path: video })}` : ''}`;
  };
  // A scene that stopped after a failure is the one reading with something to do about
  // it: Retry loads that wallpaper again on that display. Nothing retries by itself, and
  // no other row offers it, because a pause or a suspension is not a fault to retry.
  const sceneModeItem = report => `<li>${e(sceneModeLine(report))}${report.mode === 'stopped_after_failure' ? ` ${button(t('Retry'), 'sceneRetry', { displayId: report.displayId }, busy)}` : ''}</li>`;
  const sceneModeReport = (settings.sceneUpdateModes || []).map(sceneModeItem).join('');
  const sceneBackendReport = (settings.sceneRenderers || []).map(report => `<li>${e(sceneRendererLine(report))}</li>`).join('');
  // Read from what actually drew a scene, not from the preference: the note it
  // gates is only true of a surface that really is on the native backend.
  const nativeSceneRunning = (settings.sceneRenderers || []).some(report => report.backend === 'native_metal');
  // The saved preference and what is running are different facts. A scene the
  // renderer could not answer for is counted as unknown rather than as applied,
  // because "we could not tell" is not evidence that the setting took.
  const sceneOptimizationRows = (settings.sceneRenderers || []).filter(report => report.backend && report.backend !== 'unknown');
  const applied = sceneOptimizationRows.filter(report => report.optimizationApplied === true).length;
  const pending = sceneOptimizationRows.filter(report => report.optimizationApplied === false).length;
  const unknownApplied = sceneOptimizationRows.length - applied - pending;
  const savedState = settings.sceneOptimization ? t('Saved on') : t('Saved off');
  const total = sceneOptimizationRows.length;
  const sceneOptimizationStatus = total === 0
    ? ''
    : pending > 0
      ? t('{saved}; applying to {pending} of {total} running scenes on their next frame.', { saved: savedState, pending, total })
      : unknownApplied > 0
        ? t('{saved}; {applied} of {total} running scenes confirmed, the rest could not be read.', { saved: savedState, applied, total })
        : applied === 1 ? t('{saved} and in force on the running scene.', { saved: savedState }) : t('{saved} and in force on all {applied} running scenes.', { saved: savedState, applied });
  const noVideo = `<span class="settings-status" role="status">${e(t('No video wallpaper is running.'))}</span>`;
  const noScene = `<span class="settings-status" role="status">${e(t('No scene wallpaper is running.'))}</span>`;
  const preset = activeQualityPreset(settings);
  const capSlider = frameRateCapSlider(settings);
  const capDraft = drafts.has('frameRateCap') ? drafts.get('frameRateCap') : capSlider.value;
  const presetButtons = [...qualityPresetLabels, ['custom', 'Custom']].map(([id, label]) => {
    const pressed = preset === id;
    const custom = id === 'custom';
    return `<button type="button" class="settings-segment-button" aria-pressed="${pressed}" data-key="preset-${id}"${custom ? '' : ` data-action="setting" data-args="${e(JSON.stringify({ key: 'qualityPreset', value: id }))}"`}${disabled(custom || busy || unavailable)}>${e(t(label))}</button>`;
  }).join('');
  const rules = Array.isArray(settings.appRules) ? settings.appRules : [];
  const ruleRow = rule => {
    const id = String(rule.id ?? '');
    const name = rule.name || rule.bundleID || t('App');
    const data = key => `data-app-rule="${e(id)}" data-app-rule-key="${key}"`;
    return `<div class="settings-rule" data-key="rule-${e(id)}"><span class="settings-rule-name">${e(name)}</span>${select(`rule-${id}-condition`, t('Condition for {app}', { app: name }), draft(`rule-${id}-condition`, rule.condition), localizedOptions(appRuleConditions), data('condition'), busy || unavailable)}${select(`rule-${id}-action`, t('Action for {app}', { app: name }), draft(`rule-${id}-action`, rule.action), localizedOptions(appRuleActions), data('action'), busy || unavailable)}${button(t('Remove'), 'appRuleRemove', { id }, busy || unavailable)}</div>`;
  };
  const rulesEditor = `${rules.length ? rules.map(ruleRow).join('') : `<p class="settings-empty" data-key="app-rules-empty">${e(t('No app rules yet. Add an app to pause, mute or stop wallpapers while it is running or in front.'))}</p>`}<div class="settings-form-actions" data-key="app-rules-add">${button(t('Add app…'), 'appRuleAdd', {}, busy || unavailable)}</div>`;
  const energy = group('performance-energy', t('Energy use'),
    row('energy-use', t('This app, last few seconds'), energyControl(e), t('Right after you apply a wallpaper, these figures include loading it, which can take several watts for a few seconds.'), 'settings-readout settings-energy')
    + disclosure('energy-method', t('How it’s measured'), paragraphs(
      t('macOS shares GPU energy between apps by GPU time.'),
      t('Includes the control panel, the lock screen and the CPU side of video decoding. Screen compositing, the hardware video decoder, videos played with Native video, memory and the display itself are not included.'),
      t('Low: below 0.5 W. Medium: 0.5 W to below 2 W. High: 2 W or more.'),
      t('Change a quality setting below to compare energy use.')), 'settings-energy-help'));
  // The option needs a second display to mean anything; it stays on screen while on, so it can be turned off.
  const enabledDisplayCount = (state.displays || []).filter(display => display.enabled).length;
  const playback = group('performance-playback', t('Playback'),
    settingToggle('wallpapersMuted', 'Mute all wallpapers', false, t('Silences every wallpaper without changing their saved sound or volume. It works together with the rules below.'))
    + row('desktop-covered', t('When windows cover the desktop'), select('desktopCoveredAction', t('When windows cover the desktop'), draft('desktopCoveredAction', settings.desktopCoveredAction || 'pause'), localizedOptions(desktopCoveredActions), 'data-setting="desktopCoveredAction"', busy || unavailable), t('Covered means windows hide everything but the menu bar and the screen edges. Pause keeps the last frame there. Wallpapers you can’t see at all always pause.'))
    + (enabledDisplayCount >= 2 || settings.playOnlyOnActiveDisplay
      ? settingToggle('playOnlyOnActiveDisplay', 'Only play on the display I’m using', false, t('The display your pointer is on keeps playing. The others pause a few seconds after you leave them and resume the moment you return. Your own Play and Pause are not changed.'))
      : '')
    + row('other-audio', t('When another app plays sound'), select('otherAudioAction', t('When another app plays sound'), draft('otherAudioAction', settings.otherAudioAction || 'keepRunning'), localizedOptions(otherAudioActions), 'data-setting="otherAudioAction"', busy || unavailable), t('Mute silences scene and video wallpapers, and Web wallpapers when page-output mute is available. Pause applies to every wallpaper.'))
    + row('display-sleep', t('When displays sleep'), select('displaySleepAction', t('When displays sleep'), draft('displaySleepAction', settings.displaySleepAction || 'pause'), localizedOptions(displaySleepActions), 'data-setting="displaySleepAction"', busy || unavailable), t('Stop frees renderer memory and reloads the wallpaper when the display wakes. Pause keeps it loaded.'))
    + row('battery-mode', t('On battery'), select('batteryMode', t('On battery'), draft('batteryMode', settings.batteryMode || 'keepRunning'), localizedOptions(batteryModes), 'data-setting="batteryMode"', busy || unavailable), t('Reduced quality uses the scale and frame rate below instead of your usual quality settings. Pause stops wallpapers until you plug in.'))
    + (reducedChosen ? row('battery-scale', t('Render scale when reduced'), select('batteryRenderScale', t('Render scale when reduced'), draft('batteryRenderScale', batteryScale), scaleOptions(batteryScale), 'data-setting="batteryRenderScale" data-number', busy || unavailable), t('Every Reduced quality choice on this page uses this render scale and frame rate.'))
      + row('battery-fps', t('Frame rate when reduced'), `<input class="settings-number" data-key="batteryTargetFps" type="number" inputmode="numeric" aria-label="${e(t('Frame rate when reduced'))}" min="1" max="240" step="1" value="${e(draft('batteryTargetFps', settings.batteryTargetFps))}" data-setting="batteryTargetFps"${disabled(busy || unavailable)}><span class="settings-unit">fps</span>`)
      + row('reduced-quality-state', t('Reduced quality'), `<span class="settings-status" role="status" data-cause="${e(reducedBy[0] || '')}">${e(qualityStatusText(reducedBy[0]))}</span>`, '', 'settings-readout') : '')
    + (settings.batteryPercent != null
      ? row('low-battery', t('When the battery is low'), select('lowBatteryAction', t('When the battery is low'), draft('lowBatteryAction', settings.lowBatteryAction || 'keepRunning'), localizedOptions(systemConditionActions), 'data-setting="lowBatteryAction"', busy || unavailable), t('Applies only while the Mac runs on battery. It ends 5 points above the level you choose, or when you plug in. The battery is at {percent}% now.', { percent: settings.batteryPercent }))
        + (settings.lowBatteryAction && settings.lowBatteryAction !== 'keepRunning' ? row('low-battery-level', t('Low battery level'), select('lowBatteryThreshold', t('Low battery level'), draft('lowBatteryThreshold', settings.lowBatteryThreshold ?? 20), lowBatteryLevels, 'data-setting="lowBatteryThreshold" data-number', busy || unavailable)) : '')
      : '')
    + row('low-power', t('In Low Power Mode'), select('lowPowerModeAction', t('In Low Power Mode'), draft('lowPowerModeAction', settings.lowPowerModeAction || 'keepRunning'), localizedOptions(systemConditionActions), 'data-setting="lowPowerModeAction"', busy || unavailable), settings.lowPowerMode ? t('Low Power Mode is on now.') : t('Low Power Mode is off now.'))
    + row('thermal', t('When the Mac is hot'), select('thermalAction', t('When the Mac is hot'), draft('thermalAction', settings.thermalAction || 'keepRunning'), localizedOptions(systemConditionActions), 'data-setting="thermalAction"', busy || unavailable), settings.thermalAction === 'reduceQuality'
      ? t('Reduced quality applies while the Mac is hot, and wallpapers pause if it becomes very hot. Right now it is {state}.', { state: t(thermalStates[settings.thermalState] || 'normal') })
      : t('Applies while macOS reports the Mac as hot or very hot, which is when it starts slowing itself down. Right now it is {state}.', { state: t(thermalStates[settings.thermalState] || 'normal') }))
    + row('focus', t('Focus'), button(t('Open Focus Settings…'), 'openFocusSettings', {}, busy), settings.focusAction && settings.focusAction !== 'keepRunning' ? t('A Focus filter is in effect now: {action}.', { action: t(focusActions[settings.focusAction] || settings.focusAction) }) : t('In System Settings → Focus, add the WallpaperMachine filter to pause, mute, stop or temporarily switch wallpapers. No Focus filter is in effect now.'))
    + row('app-rules', t('App rules'), '', t('Pause, mute or stop wallpapers while a chosen app is running or in front.')) + disclosure('app-rules-editor', t('Edit…'), rulesEditor));
  const quality = group('performance-quality', t('Quality'),
    row('quality-preset', t('Preset'), `<div class="settings-segment" role="group" aria-label="${e(t('Quality preset'))}">${presetButtons}</div>`, t('Low, Medium and High set the frame-rate limit and render scale together. Custom means the current values match none of those.'))
    + row('frame-rate-cap', t('Frame rate limit'), `<input data-key="frameRateCap" type="range" aria-label="${e(t('Frame rate limit'))}" min="10" max="${capSlider.max}" step="1" value="${e(capDraft)}" data-setting="frameRateCap"${disabled(busy || unavailable)}><output class="settings-unit" data-value-for="frameRateCap">${e(frameRateCapReadout(capDraft, capSlider.max))}</output>`, t('At the top of the slider there is no limit, and each display runs at its own frame rate: up to 60 fps unless you chose more for it. A lower value caps every display; saved per-display frame rates are not rewritten.'))
    + row('render-scale', t('Internal render scale'), select('renderScale', t('Internal render scale'), draft('renderScale', preferredScale), scaleOptions(preferredScale), 'data-setting="renderScale" data-number', busy || unavailable || !scaleSupported), scaleSupported ? t('Renders at a lower resolution and scales the result to fill the same area. Size and position on screen don’t change.') : t('Not applicable to the wallpapers currently running'))
    + (scaleSupported && scaleOverridden ? row('render-scale-effective', t('Effective now'), `<span class="settings-status" role="status">${e(qualityEffectiveText(reducedBy[0], { effective: percent(settings.renderScale), saved: percent(settings.preferredRenderScale) }))}</span>`, '', 'settings-readout') : ''));
  const sceneGroup = group('performance-scene', t('Scene wallpapers'),
    row('scene-renderer', t('Scene renderer'), select('sceneRenderer', t('Scene renderer'), draft('sceneRenderer', settings.sceneRenderer), localizedOptions(sceneRenderers), 'data-setting="sceneRenderer"', busy || unavailable), t('Unsupported scenes use Compatibility. Lock screen playback always uses Compatibility.'))
    + settingToggle('sceneOptimization', 'Scene render optimisation', false, `${t('Skips rendering work that wouldn’t change the picture, such as parts of a scene that stay the same. Resolution, frame rate and animation speed are unaffected. Works with both scene renderers. Turn it off to compare.')}${nativeSceneRunning ? ` ${t('How much can be skipped depends on the scene. If everything in it moves, nothing is skipped.')}` : ''}`)
    + settingToggle('sceneOnDemand', 'Update only when the scene changes', false, t('When a scene has nothing left to animate, it stops drawing until something changes. Scenes that are still moving keep running normally, and scripts, sound and input keep working.'))
    + disclosure('scene-diagnostics', t('Live diagnostics'),
      row('scene-renderer-report', t('Drawn by'), sceneBackendReport ? `<ul class="settings-list">${sceneBackendReport}</ul>` : noScene, '', 'settings-readout')
      + (sceneOptimizationStatus ? row('scene-optimization-state', t('In force now'), `<span class="settings-status" role="status">${e(sceneOptimizationStatus)}</span>`, '', 'settings-readout') : '')
      + row('scene-update-report', t('Updating now'), sceneModeReport ? `<ul class="settings-list">${sceneModeReport}</ul>` : noScene, '', 'settings-readout'), 'settings-performance-diagnostics')
    + disclosure('scene-compatibility', t('Renderer compatibility'), paragraphs(t('Native Metal draws a scene only if it supports everything in it: image layers, sprite-sheet animation, 2D puppets with their own skinning shader, 2D sprite, sprite-trail, rope and rope-trail particles, 3D models, perspective cameras, scene lights, standard effect chains and post-processing, effects that read the previous frame, layer links, and BGRA or 8-bit NV12 video textures. Scenes with anything else, such as lit particles or HDR video, use Compatibility. This applies to desktop wallpapers only; the lock screen always uses Compatibility.'))));
  const videoGroup = group('performance-video', t('Video backend'),
    row('video-backend', t('Video playback'), select('videoBackend', t('Video playback backend'), draft('videoBackend', settings.videoBackend), localizedOptions(videoBackends), 'data-setting="videoBackend"', busy || unavailable), t('Native plays supported videos through macOS and uses Compatibility for the rest.'))
    + disclosure('video-diagnostics', t('Live diagnostics'), row('video-backend-report', t('In use now'), backendReport ? `<ul class="settings-list">${backendReport}</ul>` : noVideo, '', 'settings-readout'), 'settings-performance-diagnostics'));
  const experimentalGroup = group('performance-experimental', t('Experimental'),
    settingToggle('contentPacing', 'Content pacing', false, t('Experimental. Presents frames at the content’s own frame rate instead of the display’s refresh rate.'))
    + settingToggle('sharedVideoDecode', 'Shared video decode', false, t('Experimental. Screens showing the same video share one decoder.'))
    + (sessions || consumers ? row('shared-decode-report', t('Shared decode in use'), `<span class="settings-status" role="status">${e(t('{sessions} serving {surfaces}', { sessions: t(sessions === 1 ? '{count} session' : '{count} sessions', { count: sessions }), surfaces: t(consumers === 1 ? '{count} surface' : '{count} surfaces', { count: consumers }) }))}</span>`, '', 'settings-readout') : '')
    + settingToggle('sceneVideoPlaneSampling', 'Direct video plane sampling', false, t('Experimental. In scenes drawn by Native Metal, lets a layer’s shader read video frames directly instead of converting them to a color image every frame. Only works with 8-bit NV12 video and shaders that support it; everything else converts as before. Live diagnostics under Scene wallpapers shows which path each scene uses.')));
  const performance = energy + quality + playback
    + disclosure('performance-advanced', t('Advanced'), videoGroup + sceneGroup + experimentalGroup, 'settings-group settings-performance-advanced', t('Renderers & experimental options'))
    + disclosure('performance-context', t('What these settings change'), paragraphs(
      t('Wallpapers you can’t see, such as behind a full-screen app, pause on their own. When windows cover the desktop, Pause keeps the last frame and Keep running keeps it moving in the gaps.'),
      t('With two or more displays, Only play on the display I’m using pauses the others a few seconds after your pointer leaves them.'),
      t('When another app plays sound, Mute uses each wallpaper’s output mute channel. Web mute availability is shown in its details. Pause stops every wallpaper until that sound ends.'),
      t('When displays sleep, Pause keeps wallpapers loaded. Stop frees renderer memory and reloads them when the display wakes.'),
      t('On battery, Keep running leaves quality alone, Reduced quality uses the battery scale and frame rate, and Pause stops wallpapers until you plug in. None of these promises a measured power saving.'),
      t('When the battery is low, wallpapers pause or stop once the charge falls to the level you chose, and resume when you plug in or the charge recovers.'),
      t('App rules pause, mute or stop wallpapers while a chosen app is running or in front. Your own Play and Pause are not changed.'),
      t('Low Power Mode, a hot Mac and a Focus filter work the same way: while they hold, wallpapers pause, mute or stop as you chose, and resume when they end. Stop frees renderer memory and reloads wallpapers afterwards.'),
      t('In Low Power Mode, when the Mac is hot or when the battery is low, Reduced quality keeps wallpapers running at the lower render scale and frame rate instead of pausing them, and never goes above your own quality settings. If the Mac gets very hot, wallpapers pause instead. It promises no measured power saving.'),
      t('A quality preset sets the frame-rate limit and render scale together. The frame-rate limit caps every display without rewriting the frame rate saved for each wallpaper. Internal render scale sets how many pixels are rendered before the image is scaled to fit.'),
      t('Video playback picks a backend for each wallpaper. Native is used only for videos it supports; the rest play in Compatibility.'),
      t('Scene render optimisation reuses work inside a scene and produces the same picture. It only affects scene wallpapers.'),
      t('Content pacing, shared video decode and direct video plane sampling are experimental. Shared decode merges only the decoding; each screen still draws its own frames. Direct plane sampling skips a color conversion when a layer’s shader can handle it; otherwise the picture is produced as before.')));

  // Theme preferences live natively and stay usable even when renderer settings are unavailable.
  const theme = { mode: 'system', accent: '#80bbff', tone: 'neutral', icon: 'day', ...(window.__appTheme || {}), ...(state.theme || {}) };
  const themeKey = name => `theme-${name}`;
  const themeBusy = name => view.pending.has(themeKey(name)) || view.pending.has(themeKey('reset'));
  const themePending = ['mode', 'accent', 'tone', 'icon', 'reset'].some(themeBusy);
  const themeValue = name => draft(themeKey(name), theme[name]);
  const accent = /^#[0-9a-f]{6}$/i.test(String(themeValue('accent'))) ? String(themeValue('accent')) : '#80bbff';
  const iconPicker = `<fieldset class="settings-icon-picker" data-key="theme-icon-picker" aria-describedby="theme-icon-note"${disabled(themeBusy('icon'))}><legend>${e(t('App icon'))}</legend><p class="settings-note" id="theme-icon-note">${e(t('Changes the Dock icon while the app is running. Finder and the menu bar stay unchanged.'))}</p><div class="settings-icon-options">${localizedOptions([['minimal', 'Minimal'], ['day', 'Day'], ['night', 'Night']]).map(([id, label]) => `<label class="settings-icon-option" data-key="theme-icon-option-${id}"><img src="app-icons/${id}.png" width="96" height="96" alt=""><span><input type="radio" name="app-icon" value="${id}" data-key="theme-icon-${id}" data-theme-setting="icon"${themeValue('icon') === id ? ' checked' : ''}${disabled(themeBusy('icon'))}>${e(label)}</span></label>`).join('')}</div></fieldset>`;
  const appearance = group('appearance-theme', '', row(themeKey('mode-row'), t('Appearance'), select(themeKey('mode'), t('Appearance'), themeValue('mode'), localizedOptions([['system', 'System (Auto)'], ['light', 'Light'], ['dark', 'Dark']]), 'data-theme-setting="mode"', themeBusy('mode')), t('System follows the macOS light and dark setting.'))
    + row(themeKey('accent-row'), t('Accent color'), `<input data-key="${e(themeKey('accent'))}" type="color" aria-label="${e(t('Accent color'))}" value="${e(accent)}" data-theme-setting="accent"${disabled(themeBusy('accent'))}><output class="settings-hex" data-value-for="${e(themeKey('accent'))}">${e(accent.toUpperCase())}</output>`, t('Colors buttons, links and focus rings.'))
    + row(themeKey('tone-row'), t('Surface tone'), select(themeKey('tone'), t('Surface tone'), themeValue('tone'), localizedOptions([['neutral', 'Neutral'], ['warm', 'Warm'], ['cool', 'Cool']]), 'data-theme-setting="tone"', themeBusy('tone')), t('Warms or cools the window background.'))
    + iconPicker
    + row(themeKey('reset-row'), t('Theme defaults'), button(t('Reset appearance'), 'resetTheme', {}, themePending), t('Restores System, the default accent, Neutral tone and the Day icon.')))
    + `<p class="settings-footnote">${e(t('Appearance changes apply right away and only affect this app’s window, not your wallpapers.'))}</p>`;

  const displays = (state.displays || []).map(display => {
    const id = display.id;
    const primary = id === 'primary';
    const mirror = display.mode === 'mirror';
    const off = busy || !display.enabled;
    const playbackOff = off || (!mirror && !display.wallpaperID);
    const options = !mirror && state.options?.id === display.wallpaperID ? state.options : null;
    const config = options?.displays?.find(item => item.id === id);
    const playback = config ? { ...display, ...config, muted: options.muted, volume: options.volume } : display;
    const data = key => `data-display="${e(id)}" data-display-setting="${key}"`;
    const key = name => `display-${id}-${name}`;
    const name = label => t('{label} for {display}', { label, display: display.title });
    const wallpaper = (state.wallpapers || []).find(item => item.id === display.wallpaperID);
    const limited = performanceLimitedFps(playback.fps, settings);
    const number = (field, label, min, max, step, suffix = '', { value = playback[field], attributes = data(field), off: inactive = playbackOff } = {}) => `<input class="settings-number" data-key="${e(key(field))}" type="number" inputmode="decimal" aria-label="${e(name(label))}"${min == null ? '' : ` min="${min}"`}${max == null ? '' : ` max="${max}"`} step="${step}" value="${e(draft(key(field), value))}" ${attributes}${disabled(inactive)}>${suffix ? `<span class="settings-unit">${e(suffix)}</span>` : ''}`;
    // The display's playlist: off, a rotation, or a day and a night wallpaper.
    const playlist = { mode: 'off', source: 'all', order: 'sequential', trigger: 'interval', interval: 30, wallpaperIDs: [], collectionID: null, planID: null, dayWallpaperID: null, nightWallpaperID: null, dayStart: 420, nightStart: 1140, nextChange: null, ...((state.playlists || {})[id] || {}) };
    const playlistData = field => `data-playlist="${e(id)}" data-playlist-key="${field}"`;
    // The menu offers the presets; any other stored interval, or choosing Custom, shows a minutes field.
    const intervalPresets = state.playlistIntervals || [];
    const [intervalMin, intervalMax] = state.playlistIntervalRange || [];
    const intervalChoice = String(draft(intervalKeys(id).menu, playlist.trigger === 'unlock' ? 'unlock' : intervalPresets.includes(Number(playlist.interval)) ? playlist.interval : 'custom'));
    const listed = (playlist.wallpaperIDs || []).map(wallpaperID => (state.wallpapers || []).find(item => item.id === wallpaperID)).filter(Boolean);
    const playable = (state.wallpapers || []).filter(item => item.supported).sort((a, b) => a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: 'base' }));
    const nextChange = playlist.nextChange != null && Number.isFinite(Number(playlist.nextChange)) ? changeTime(Number(playlist.nextChange)) : '';
    const clockInput = (field, label, minute) => `<input type="time" data-key="${e(key(`playlist-${field}`))}" aria-label="${e(name(label))}" value="${e(draft(key(`playlist-${field}`), clockValue(minute)))}" ${playlistData(field)}${disabled(off)}>`;
    const rotateRows = row(key('playlist-source-row'), t('Wallpapers'), sourceSelect(ctx, key('playlist-source'), name(t('Wallpapers')), playlist, listed.length, playlistData('source'), off), sourceNote(ctx, playlist))
      + row(key('playlist-order-row'), t('Order'), select(key('playlist-order'), name(t('Order')), draft(key('playlist-order'), playlist.order), localizedOptions(playlistOrders), playlistData('order'), off))
      + row(key('playlist-interval-row'), t('How often'), select(intervalKeys(id).menu, name(t('How often')), intervalChoice, [...intervalPresets.map(minutes => [minutes, intervalLabel(minutes)]), ['unlock', unlockLabel()], ['custom', t('Custom')]], playlistData('interval'), off))
      + (intervalChoice === 'custom' ? row(key('playlist-custom-interval-row'), t('Minutes between changes'), number('playlist-custom-interval', t('Minutes between changes'), intervalMin, intervalMax, 1, t('min'), { value: playlist.interval, attributes: playlistData('interval'), off }), intervalMax == null ? '' : t('Any whole number of minutes, up to {count}.', { count: Number(intervalMax).toLocaleString(language()) })) : '')
      + (playlist.source === 'list' ? playlistOrderMarkup(ctx, id, playlist, off) : '')
      + playlistFailures(ctx, id, playlist, off)
      + row(key('playlist-next-row'), t('Next change'), button(t('Change now'), 'playlistSkip', { displayID: id }, off), playlist.trigger === 'unlock' ? t('Changes when you unlock the Mac, while wallpapers are playing.') : nextChange ? t('Around {time}, if wallpapers are playing then.', { time: nextChange }) : t('Starts counting once wallpapers play.'));
    const wallpaperChoices = [['', t('Leave as it is')], ...playable.map(item => [item.id, item.title])];
    const dayNightRows = row(key('playlist-day-row'), t('Day wallpaper'), select(key('playlist-day'), name(t('Day wallpaper')), draft(key('playlist-day'), playlist.dayWallpaperID || ''), wallpaperChoices, playlistData('dayWallpaper'), off))
      + row(key('playlist-day-start-row'), t('Day starts at'), clockInput('dayStart', t('Day starts at'), playlist.dayStart))
      + row(key('playlist-night-row'), t('Night wallpaper'), select(key('playlist-night'), name(t('Night wallpaper')), draft(key('playlist-night'), playlist.nightWallpaperID || ''), wallpaperChoices, playlistData('nightWallpaper'), off))
      + row(key('playlist-night-start-row'), t('Night starts at'), clockInput('nightStart', t('Night starts at'), playlist.nightStart))
      + (nextChange ? row(key('playlist-switch-row'), t('Next switch'), `<span class="settings-status" role="status">${e(t('Around {time}.', { time: nextChange }))}</span>`, '', 'settings-readout') : '');
    const playlistMode = playlistModes.find(([mode]) => mode === playlist.mode) || playlistModes[0];
    // The user removed this display's wallpaper, so the playlist leaves it empty until it is resumed.
    const held = playlist.held === true && playlist.mode !== 'off';
    const playlistRows = mirror ? '' : disclosure(key('playlist'), playlist.mode === 'off' ? t('Playlist') : t('Playlist: {mode}', { mode: t(playlistMode[1]) }),
      row(key('playlist-mode-row'), t('Changes on its own'), select(key('playlist-mode'), name(t('Changes on its own')), draft(key('playlist-mode'), playlist.mode), localizedOptions(playlistModes), playlistData('mode'), off), t('Only while wallpapers play. A change that falls due while they are paused, the screen is locked or the displays sleep happens once they play again.'))
      + (held ? row(key('playlist-held-row'), t('Playlist paused'), button(t('Resume playlist'), 'playlistResume', { displayID: id }, off), t('This display’s wallpaper was removed, so its playlist waits until you choose a wallpaper or resume it.')) : '')
      + (playlist.mode === 'rotate' ? rotateRows : playlist.mode === 'dayNight' ? dayNightRows : '')
      + planRows(ctx, display, playlist, off), 'settings-disclosure-rows', held ? t('Playlist paused') : '');
    return `<section class="settings-display settings-group" data-key="display-${e(id)}" aria-labelledby="settings-group-display-${e(id)}"><h3 id="settings-group-display-${e(id)}">${e(display.title)}${primary ? `<span class="settings-note">${e(t('Primary display'))}</span>` : ''}</h3>`
      + row(key('enabled-row'), t('Enable wallpaper'), toggle(key('enabled'), name(t('Enable wallpaper')), draft(key('enabled'), display.enabled), data('enabled'), busy || primary))
      + row(key('mode-row'), t('Display mode'), select(key('mode'), name(t('Display mode')), draft(key('mode'), display.mode), localizedOptions([['standalone', 'Independent'], ['mirror', 'Mirror another display']]), data('mode'), off || primary))
      + (mirror ? row(key('target-row'), t('Mirror source'), select(key('mirrorTarget'), name(t('Mirror source')), draft(key('mirrorTarget'), display.mirrorTarget), [['', t('Choose display')], ...(display.mirrorTargets || []).map(target => [target.id, target.title])], data('mirrorTarget'), off || !display.mirrorTargets?.length), !display.mirrorTargets?.length ? t('No compatible display available.') : '') : row(key('wallpaper-row'), t('Wallpaper'), button(t('Choose…'), 'chooseDisplayWallpaper', { displayID: id }, off) + button(t('Eject'), 'eject', { id: display.wallpaperID, displayID: id }, off || !display.wallpaperID), wallpaper?.title || (display.wallpaperID ? display.wallpaperID : t('None selected'))))
      + playlistRows
      + displayTransferRow(ctx, display, off)
      + automationRows(ctx, display, off || mirror)
      + disclosure(key('advanced'), t('Playback & scaling'), (!mirror && !display.wallpaperID ? `<div class="settings-note">${e(t('Choose a wallpaper to adjust playback.'))}</div>` : '') + row(key('scaling-row'), t('Scaling'), select(key('scalingMode'), name(t('Scaling')), draft(key('scalingMode'), playback.scalingMode), localizedOptions([['none', 'No scaling'], ['stretch', 'Stretch'], ['match', 'Match'], ['fill', 'Fill']]), data('scalingMode'), playbackOff))
        + row(key('factor-row'), t('Scale factor'), number('scalingFactor', t('Scale factor'), Number.MIN_VALUE, null, 'any', '×'))
        + row(key('fps-row'), t('Frame rate'), number('fps', t('Frame rate'), 1, playback.maxFps || 60, 1, 'fps'))
        + (limited == null ? '' : `<p class="settings-note settings-limit-note" data-key="${e(key('fps-limit'))}">${e(t('Limited to {fps} fps by Performance settings', { fps: limited }))} ${button(t('Open Performance'), 'openPerformance')}</p>`)
        + row(key('muted-row'), t('Mute audio'), toggle(key('muted'), name(t('Mute audio')), draft(key('muted'), playback.muted), data('muted'), playbackOff))
        + row(key('volume-row'), t('Volume'), `<input data-key="${e(key('volume'))}" type="range" aria-label="${e(name(t('Volume')))}" min="0" max="1" step="0.01" value="${e(draft(key('volume'), playback.volume))}" ${data('volume')}${disabled(playbackOff || playback.muted)}><output class="settings-unit" data-value-for="${e(key('volume'))}">${Math.round(Number(draft(key('volume'), playback.volume || 0)) * 100)}%</output>`), 'settings-disclosure-rows') + '</section>';
  }).join('') || `<div class="settings-empty">${e(t('No displays connected.'))}</div>`;
  const displaysPage = displays + displayLayoutsGroup(ctx) + plansGroup(ctx) + solarLocationGroup(ctx);

  const scenePending = Boolean(scene?.pending);
  const sceneRequest = (state.downloadRequests || []).find(request => request.id === 'scene-assets');
  const sceneAuth = scenePending && !scene.queued && Boolean(scene.prompt || scene.challenge || scene.authenticating);
  const setupLocked = busy || setup.busy || anyDownload;
  const setupControls = setup.busy ? button(t('Cancel installation'), 'setupCancel', {}, busy || setup.canCancel === false) : button(setup.candidatePath ? t('Continue installation') : setup.ready ? t('Reinstall…') : t('Install SteamCMD'), 'setupInstall', {}, setupLocked, !setup.ready ? 'settings-primary' : '') + button(t('Locate…'), 'setupLocate', {}, setupLocked);
  const candidate = setup.candidatePath ? row('candidate', t('Downloaded installation'), button(t('Show in Finder'), 'setupRevealCandidate', {}, busy) + button(t('Discard…'), 'setupDiscardCandidate', {}, setupLocked, 'settings-destructive'), setup.candidatePath) : '';
  const progress = setup.busy && Number.isFinite(setup.progress) ? `<progress class="settings-progress" max="1" value="${Math.max(0, Math.min(1, setup.progress))}" aria-label="${e(t('SteamCMD installation progress'))}"></progress>` : '';
  const sceneStatus = scene ? scene.status
    : sceneRequest ? sceneRequest.stage === 'setup' ? t('Waiting for SteamCMD setup.') : sceneRequest.stage === 'account' ? t('Waiting for your Steam sign-in.') : t('Waiting for your go-ahead on the download.')
      : settings.sceneAssetsReady ? t('Installed. Scene wallpapers can play.') : t('Not installed. Scene wallpapers cannot play yet.');
  // Downloading, signing in and Steam Guard all happen in the panel's download dialog; this is a summary with one way in.
  const sceneSummary = `<section class="settings-group" data-key="scene-resources" aria-busy="${scenePending}" aria-labelledby="settings-group-scene-resources"><h3 id="settings-group-scene-resources">${e(t('Shared scene resources'))}</h3>${row('assets-ready', t('Installation'), `<span class="settings-status" role="status">${e(sceneStatus)}</span>`, '', 'settings-readout')}`
    + (scenePending ? `<progress class="settings-progress" max="1"${Number.isFinite(scene.progress) ? ` value="${Math.max(0, Math.min(1, scene.progress))}"` : ''} aria-label="${e(t('Shared resources download progress'))}"></progress>` : '')
    + error('scene-error', scene?.error)
    + (scene?.warning ? `<div class="settings-notice" role="status">${e(scene.warning)}</div>` : '')
    + (settings.sceneAssetsWarning ? `<div class="settings-notice" role="status">${e(settings.sceneAssetsWarning)}</div>` : '')
    + `<div class="settings-form-actions">`
    + (sceneAuth ? button(t('Finish sign-in…'), 'openSceneDialog', {}, busy, 'settings-primary') : '')
    + (scenePending ? button(scene.queued ? t('Cancel queued download') : t('Cancel download'), 'downloadCancel', { id: scene.id }, busy) : '')
    + (!scenePending && sceneRequest ? button(t('Continue setup…'), 'openSceneDialog', {}, busy, 'settings-primary') + button(t('Remove request'), 'removeDownloadRequest', { id: sceneRequest.id }, busy, 'settings-destructive') : '')
    + (!scenePending && !sceneRequest ? button(settings.sceneAssetsReady ? t('Download again…') : t('Download from Steam…'), 'requestSceneAssets', {}, busy, settings.sceneAssetsReady ? '' : 'settings-primary') : '')
    + (!scenePending ? button(t('Locate an installation…'), 'locateAssets', {}, busy || setup.busy) : '')
    + `</div><p class="settings-note">${e(t('Steam downloads the full Windows version to a temporary folder, and only the shared resources are kept. No Windows programs are run. You need several GB of free space and a Steam account that owns Wallpaper Engine.'))}</p></section>`;
  // The setting is the ceiling; downloadSlots is what applies now (1 after Steam ended a session).
  const slots = Number(settings.concurrentDownloads) || 1;
  const slotChoices = Array.from({ length: Math.max(slots, Number(settings.concurrentDownloadsMax) || 1) }, (_, index) => [index + 1, String(index + 1)]);
  const serialNow = slots > 1 && Number(state.downloadSlots) === 1;
  const updates = state.workshopUpdates || {};
  const library = group('library-folder', '', row('library-path', t('Wallpaper library'), button(t('Show in Finder'), 'showLibrary', {}, busy), settings.libraryPath || t('Unavailable')))
    + group('library-steamcmd', 'SteamCMD', row('steam-status', t('Installation'), `<span class="settings-status" role="status">${e(setup.status || (setup.ready ? t('Ready') : t('Not installed')))}</span>`, '', 'settings-readout')
    + progress
    + `<div class="settings-form-actions">${setupControls}${setup.canApprove ? button(t('Allow this SteamCMD…'), 'setupApprove', {}, setupLocked) : ''}</div>`
    + candidate + error('setup-error', setup.error)
    + (anyDownload && !setup.busy ? `<div class="settings-note">${e(t('Installation changes are unavailable while downloads are running.'))}</div>` : ''))
    + sceneSummary
    + group('library-updates', t('Workshop updates'), row('workshop-update-checks', t('Check once a day'), toggle('workshopUpdateChecks', t('Check once a day'), draft('workshopUpdateChecks', updates.automatic !== false), 'data-setting="workshopUpdateChecks" aria-describedby="settings-note-workshop-update-checks"', busy), t('Asks Steam which of your installed Workshop wallpapers have changed since you got them. Only their ids are sent, and no sign-in is needed.'), '', 'workshopUpdateChecks')
      + row('workshop-update-status', t('Last check'), button(updates.checking ? t('Checking…') : t('Check Now'), 'workshopCheckUpdates', {}, busy || updates.checking), updates.lastChecked != null ? (Number(updates.count) ? t('{time}: {count} wallpapers have updates. Update them from Installed.', { time: changeTime(Number(updates.lastChecked)), count: Number(updates.count) }) : t('{time}: everything is up to date.', { time: changeTime(Number(updates.lastChecked)) })) : t('Not checked yet.'))
      + error('workshop-update-error', updates.error))
    + group('library-downloads', t('Downloads'), row('concurrent-downloads', t('Downloads at once'), select('concurrentDownloads', t('Downloads at once'), draft('concurrentDownloads', slots), slotChoices, 'data-setting="concurrentDownloads" data-number aria-describedby="settings-note-concurrent-downloads"', busy || unavailable), serialNow ? t('Steam ended one of the sessions, so downloads run one at a time until you reopen the app.') : t('Each download signs in to Steam on its own. More at once mostly helps batches of small wallpapers; large ones share your connection.')))
    + group('library-account', '', row('steam-account', t('Steam account'), state.savedAccount ? button(t('Log out…'), 'logOutSteam', {}, anyDownload || busy, 'settings-destructive') : `<span class="settings-note">${e(t('Not signed in'))}</span>`, state.savedAccount ? `${t('Signed in as {account}', { account: state.savedAccount })}${anyDownload ? t(' · log out once downloads finish') : ''}` : t('You sign in when a download starts.'))
    + row('welcome-guide', t('Welcome guide'), button(t('Show again'), 'openWelcome'), t('Shown on first launch: language and appearance, Steam sign-in, preferences and tips.'))
    + disclosure('library-context', t('Setup, compatibility & account privacy'), `${paragraphs(t('Scene wallpapers need shared resources from a purchased Wallpaper Engine installation. Videos do not. Locate its assets folder or download the shared assets once through Steam. Scene support is experimental; effects and scripts may differ from Windows.'), t('Steam downloads the Windows version to temporary storage; only shared assets are kept. Windows programs are never run. Allow several GB of temporary space. Imports are copied; original files and your Steam library stay untouched.'), t('SteamCMD is Valve’s download tool; installing it doesn’t require signing in. Downloading requires a Steam account that owns Wallpaper Engine. Your password and Steam Guard codes go straight to SteamCMD and are not saved by this app. “Keep me signed in” stores Steam’s sign-in on this Mac. Logging out only affects this Mac; other devices stay signed in.'), t('Approve Steam Guard in the Steam mobile app, or enter the fresh code when requested. Steam may require a new sign-in after expiry or security changes. If Steam reports too many attempts, wait before retrying.'), t('Allowing SteamCMD applies only to the downloaded copy you confirmed. Gatekeeper and signature checks stay on.'))}${settings.assetsPath ? `<div class="settings-path">${e(settings.assetsPath)}</div>` : ''}<div class="settings-help-links">${button(t('Wallpaper Engine on Steam'), 'openExternal', { url: 'https://store.steampowered.com/app/431960/Wallpaper_Engine/' })}${button(t('macOS app security'), 'openExternal', { url: 'https://support.apple.com/en-us/102445' })}</div>`));
  // Nil released-bytes means no purge has run this session; 0 means one ran and
  // found nothing. They read differently on purpose.
  const released = settings.userAssetsReleasedBytes;
  const storage = group('storage-user-assets', t('Wallpaper files you chose'), `<p class="settings-path" data-key="user-assets-path">${e(settings.userAssetsPath || t('Unavailable'))}</p>`
    + `<p class="settings-note" data-key="user-assets-note">${e(t('Files you pick in a wallpaper’s settings are copied here. “Clear unused caches” only removes caches that can be rebuilt, never files you added.'))}${released == null ? '' : ` ${e(t('Last clear released {size}.', { size: bytes(released) }))}`}</p>`
    + `<div class="settings-form-actions">${button(t('Show in Finder'), 'revealUserAssets', {}, busy || unavailable)}${button(t('Clear unused caches…'), 'purgeUnreferencedUserAssets', {}, busy || unavailable)}</div>`)
    + group('storage-caches', '', row('shader-cache', t('Shader cache'), button(t('Clear…'), 'clearCache', {}, busy || unavailable || !settings.shaderCacheBytes), bytes(settings.shaderCacheBytes))
    + row('logs', t('Logs'), button(t('Show in Finder'), 'showLogs', {}, busy || unavailable) + button(t('Clear…'), 'clearLogs', {}, busy || unavailable || !settings.logBytes), bytes(settings.logBytes))
    + row('download-history', t('Completed downloads'), button(t('Clear history'), 'clearDownloads', {}, busy || !downloads.some(download => !download.pending)))
    + disclosure('storage-context', t('What gets removed'), paragraphs(t('Clearing the shader cache removes compiled shaders and render pipelines. They are rebuilt as wallpapers load, which can briefly slow playback. Clearing logs doesn’t affect wallpapers or settings. Clearing download history keeps the downloaded files.'), t('Files you chose in a wallpaper’s settings are copied to the folder above, so clearing caches or updating the wallpaper won’t remove them. To remove one, clear that setting on the wallpaper.'))))
    + backupGroup(ctx, language())
    + group('storage-diagnostics', t('Troubleshooting'), settingToggle('verboseLogging', 'Detailed logging', false, t('Records extra detail from now on, including after a restart. Turn it off when you are done.'))
      + settingToggle('inspectWebWallpapers', 'Allow inspecting web wallpapers', false, t('Lets Safari’s Develop menu attach to the web wallpapers running on this Mac so you can debug a page. Turn it off when you are done.'))
      + row('diagnostics-export', t('Diagnostics report'), button(t('Export…'), 'exportDiagnostics', {}, busy || unavailable), t('Saves recent logs, the lock screen log, macOS crash, resource, spin and hang reports, which wallpapers were loading when WallpaperMachine quit unexpectedly, and a system summary as one .zip file to attach to a bug report. Home folder paths, your Mac user name and Steam account names are replaced.'))
      + settingToggle('telemetry', 'Send performance data', !settings.telemetryAvailable, t('Sends once a day: how long wallpapers take to apply, their frame rate and energy use, how the app quit, your Mac’s model, and the Workshop ids of the wallpapers measured. No names, files or account details. Turning it off asks for the sent data to be deleted.'))
      + row('telemetry-data', t('Data to be sent'), button(t('Show in Finder'), 'telemetryShowData', {}, busy || !settings.telemetry) + button(t('What is sent'), 'telemetryDetails', {}),
        !settings.telemetry ? '' : Number.isFinite(settings.telemetryLastSent) ? t('Last sent on {date}.', { date: new Date(settings.telemetryLastSent).toLocaleDateString(language()) }) : t('Nothing sent yet.')));
  const versionRow = (id, label, value) => row(id, label, `<span class="settings-version">${e(value || t('Unavailable'))}</span>`);
  const update = state.update || {};
  const updateBusy = Boolean(update.busy) || ['checkForUpdates', 'downloadUpdate', 'installUpdate', 'openReleases', 'revealDownloadedUpdate'].some(action => view.pending.has(action));
  const updateProgress = update.status === 'downloading'
    ? `<progress class="settings-progress" max="1" value="${Math.max(0, Math.min(1, Number(update.percent || 0) / 100))}" aria-label="${e(update.progressLabel || t('Update download progress'))}"></progress>`
      + (Number(update.total) > 0 ? `<div class="settings-note">${e(t('{received} of {expected}', { received: bytes(update.transferred), expected: bytes(update.total) }))}</div>` : '')
    : '';
  // The release body the app shows is what scripts/release_notes.py wrote from the
  // commits; its headings go through t() so a known one is translated and an
  // unexpected one still reads.
  const noteSections = (Array.isArray(update.notes) ? update.notes : []).filter(part => (part.items || []).length);
  const updateNotes = noteSections.length
    ? disclosure('about-notes',
      update.notesVersion ? t('What’s new in {version}', { version: update.notesVersion }) : t('What’s new'),
      `<div class="settings-notes">${noteSections.map(part => (part.title ? `<h4>${e(t(part.title))}</h4>` : '')
        + `<ul>${(part.items || []).map(item => `<li>${e(item)}</li>`).join('')}</ul>`).join('')}</div>`)
    : '';
  const updateActions = (update.showsAction && update.action ? button(update.actionLabel || t('Check for Updates'), update.action, {}, update.action === 'cancelUpdate' ? view.pending.has('cancelUpdate') : updateBusy || busy, update.status === 'available' || update.status === 'ready' ? 'settings-primary' : '') : '')
    + (update.showsReleases ? button(update.releasesLabel || t('Open GitHub Releases'), 'openReleases', {}, updateBusy) : '')
    + (update.showsReveal ? button(update.revealLabel || t('Show in Finder'), 'revealDownloadedUpdate', {}, updateBusy) : '');
  const about = `<div class="settings-product"><span class="settings-product-mark">${helpers.icon('wallpaperMachine', 48)}</span><div><h3>WallpaperMachine</h3><span class="settings-note">${e(t('Independent macOS client'))}</span></div></div>`
    + group('about-versions', '', versionRow('app-version', t('App version'), state.version)
      + versionRow('git-version', t('Git revision'), settings.gitSha))
    + `<section class="settings-group" data-key="about-updates" aria-busy="${updateBusy}" aria-labelledby="settings-group-about-updates"><h3 id="settings-group-about-updates">${e(t('Updates'))}</h3><div class="settings-status" role="status" aria-live="polite">${e(update.statusText || t('Updates not yet checked'))}</div>`
    + updateProgress
    + `<div class="settings-form-actions">${updateActions}</div>`
    + updateNotes
    + `<p class="settings-note settings-update-footnote">${e(update.footnote || t('Updates are checked against the latest published GitHub Release. Download and restart-install happen only after you confirm.'))}</p></section>`
    + group('about-share', t('Spread the word'), `<div class="settings-form-actions">${button(t('Share WallpaperMachine…'), 'shareApp', {})}${button(t('Star on GitHub'), 'starRepository', {})}</div>`)
    + group('about-credits', '', `<div class="settings-attribution">${e(t('Not affiliated with Wallpaper Engine or Valve. Built on the GPLv2-only open-source renderer. Workshop browsing is independently implemented. No warranty is provided.'))}</div>`
    + `<div class="settings-form-actions">${button(t('GNU General Public License v2'), 'openExternal', { url: 'https://www.gnu.org/licenses/old-licenses/gpl-2.0.html' })}</div>`);
  const html = `<div class="settings-layout" data-key="settings-layout"><nav class="settings-nav" aria-label="${e(t('Settings categories'))}" role="tablist" aria-orientation="${compactNavigation.matches ? 'horizontal' : 'vertical'}" data-key="settings-nav">${sections.map(([id, title, glyph]) => `<button type="button" id="settings-tab-${id}" role="tab" aria-selected="${id === view.section}" aria-controls="settings-${id}" tabindex="${id === view.section ? '0' : '-1'}" data-key="nav-${id}" data-section="${id}">${helpers.icon(glyph, 16)}<span>${e(t(title))}</span></button>`).join('')}</nav><div class="settings-scroll" data-key="settings-scroll">${error('settings-action-error', view.error || state.error)}${unavailable ? `<div class="settings-notice" role="status">${e(t('Settings are unavailable. Try refreshing the library.'))}</div>` : ''}${section('general', t('General'), general)}${section('appearance', t('Appearance'), appearance)}${section('performance', t('Performance'), performance)}${section('displays', t('Displays'), displaysPage, button(t('Refresh'), 'refreshDisplays', {}, busy))}${section('library', t('Library & Steam'), library)}${section('storage', t('Storage'), storage)}${section('about', t('About'), about)}</div></div>`;
  const template = document.createElement('template');
  template.innerHTML = html;
  reconcile(view.container, template.content);
}

// Keep live controls, selection, IME composition, scroll positions and disclosures intact.
function reconcile(parent, desired) {
  let cursor = parent.firstChild;
  for (const incoming of Array.from(desired.childNodes)) {
    const key = incoming.nodeType === Node.ELEMENT_NODE ? incoming.getAttribute('data-key') : null;
    let existing = key ? Array.from(parent.childNodes).find(node => node.nodeType === Node.ELEMENT_NODE && node.getAttribute('data-key') === key) : cursor;
    if (!existing || existing.nodeType !== incoming.nodeType || existing.nodeName !== incoming.nodeName || (!key && existing.nodeType === Node.ELEMENT_NODE && existing.hasAttribute('data-key'))) {
      existing = incoming.cloneNode(true);
      parent.insertBefore(existing, cursor);
    } else {
      if (existing !== cursor) parent.insertBefore(existing, cursor);
      if (existing.nodeType === Node.TEXT_NODE) {
        if (existing.data !== incoming.data) existing.data = incoming.data;
      } else if (existing.nodeType === Node.ELEMENT_NODE) {
        for (const attribute of Array.from(existing.attributes)) {
          if (attribute.name === 'open' && existing.tagName === 'DETAILS') continue;
          if (!incoming.hasAttribute(attribute.name)) existing.removeAttribute(attribute.name);
        }
        for (const attribute of incoming.attributes) {
          if (existing.getAttribute(attribute.name) !== attribute.value) existing.setAttribute(attribute.name, attribute.value);
        }
        if (existing.tagName === 'INPUT') {
          if (existing.type === 'checkbox' || existing.type === 'radio') existing.checked = incoming.checked;
          else if (existing !== document.activeElement && existing.value !== incoming.value) existing.value = incoming.value;
        }
        reconcile(existing, incoming);
        if (existing.tagName === 'SELECT' && existing !== document.activeElement) existing.value = incoming.value;
      }
    }
    cursor = existing.nextSibling;
  }
  while (cursor) {
    const next = cursor.nextSibling;
    cursor.remove();
    cursor = next;
  }
}

function onInput(view, event) {
  const input = event.target;
  if (displayLayoutInput(view, input)) return;
  if (automationInput(view, input, () => draw(view))) return;
  if (!input.matches('input[data-key]') || input.type === 'radio') return;
  const key = input.dataset.key;
  view.drafts.set(key, input.type === 'checkbox' ? input.checked : input.value);
  if ('local' in input.dataset) draw(view);
  // Color pickers stream input events while the macOS picker is open; only the readout follows, never a redraw or a save.
  if (input.type === 'range' || input.type === 'color') {
    const output = Array.from(view.container.querySelectorAll('[data-value-for]')).find(node => node.dataset.valueFor === key);
    if (output) output.textContent = input.dataset.setting === 'frameRateCap' ? frameRateCapReadout(input.value, input.max) : input.type === 'color' ? String(input.value).toUpperCase() : `${Math.round(Number(input.value) * 100)}%`;
  }
}

// Leaving the custom minutes field without saving a number gives it up, so the menu and the
// field show the saved interval again. Checked after the move settles, so switching to another
// app keeps the field, and a number being saved is left to its own change.
function onFocusOut(view, event) {
  const input = event.target;
  if (input.dataset?.playlistKey !== 'interval' || input.type !== 'number') return;
  const keys = intervalKeys(input.dataset.playlist);
  setTimeout(() => {
    if (!document.hasFocus() || document.activeElement === input || view.pending.has(keys.field)) return;
    const menuDraft = view.drafts.get(keys.menu) === 'custom';
    if (!menuDraft && !view.drafts.has(keys.field)) return;
    view.drafts.delete(keys.field);
    if (menuDraft) view.drafts.delete(keys.menu);
    draw(view);
  });
}

async function onChange(view, event) {
  const input = event.target;
  if (displayLayoutChange(view, input, () => draw(view))) return;
  if (automationInput(view, input, () => draw(view))) return;
  if (input.dataset.autoMode || input.dataset.autoAppearance || input.dataset.autoSpace) {
    await automationChange(view, input, (action, args) => perform(view, action, action, args));
    return;
  }
  if ('local' in input.dataset) {
    view.drafts.set(input.dataset.key, input.type === 'checkbox' ? input.checked : input.value);
    draw(view);
    return;
  }
  if (input.dataset.languageSetting !== undefined) {
    view.drafts.set('language', input.value);
    await perform(view, 'language', 'languageSetting', { value: String(input.value) });
    view.drafts.delete('language');
    draw(view);
    return;
  }
  if (input.dataset.themeSetting) {
    const themeDraft = `theme-${input.dataset.themeSetting}`;
    const restoreFocus = input.type === 'radio' && input === document.activeElement;
    view.drafts.set(themeDraft, input.value);
    await perform(view, themeDraft, 'themeSetting', { key: input.dataset.themeSetting, value: String(input.value) });
    view.drafts.delete(themeDraft);
    draw(view);
    if (restoreFocus && document.activeElement === document.body && input.isConnected) input.focus({ preventScroll: true });
    return;
  }
  if (input.dataset.appRule) {
    const id = input.dataset.appRule;
    const ruleKey = input.dataset.appRuleKey;
    const draftKey = input.dataset.key;
    view.drafts.set(draftKey, input.value);
    await perform(view, draftKey, 'appRuleUpdate', { id, key: ruleKey, value: input.value }, () => view.drafts.delete(draftKey));
    view.drafts.delete(draftKey);
    draw(view);
    return;
  }
  if (input.dataset.planDisplay !== undefined) {
    // Choosing a saved playlist applies it to the display; the blank entry only reports.
    const planID = input.value;
    if (!planID) { draw(view); return; }
    const draftKey = input.dataset.key;
    view.drafts.set(draftKey, planID);
    await perform(view, draftKey, 'playlistPlanApply', { displayID: input.dataset.planDisplay, planID }, () => view.drafts.delete(draftKey));
    view.drafts.delete(draftKey);
    draw(view);
    return;
  }
  if (input.dataset.playlist !== undefined) {
    let field = input.dataset.playlistKey;
    let value = input.value;
    if (field === 'interval') {
      // Custom only reveals the minutes field, starting from the saved interval; nothing changes
      // until a number is entered there.
      if (value === 'custom') {
        const keys = intervalKeys(input.dataset.playlist);
        view.drafts.set(keys.menu, 'custom');
        view.drafts.delete(keys.field);
        draw(view);
        [...view.container.querySelectorAll('input[data-key]')].find(node => node.dataset.key === keys.field)?.focus();
        return;
      }
      // Unlocking is not a number of minutes: it is the playlist's trigger, which minutes replace.
      if (value === 'unlock') { field = 'trigger'; }
      else {
        if (input.type === 'number' && (!input.checkValidity() || input.value.trim() === '')) { input.reportValidity(); return; }
        value = Number(value);
      }
    }
    if (field === 'dayStart' || field === 'nightStart') {
      value = clockMinute(value);
      if (value === null) { input.reportValidity(); return; }
    }
    // A collection entry in the Wallpapers menu names the collection; native selects it and
    // the collection source together.
    if (field === 'source' && value.startsWith('collection:')) { field = 'collectionID'; value = value.slice('collection:'.length); }
    else if (field === 'source' && value === 'collection') { draw(view); return; }
    const draftKey = input.dataset.key;
    const typedInterval = field === 'interval' && input.type === 'number';
    view.drafts.set(draftKey, input.value);
    await perform(view, draftKey, 'playlistSetting', { displayID: input.dataset.playlist, key: field, value }, () => {
      view.drafts.delete(draftKey);
      // A saved typed interval that matches a preset shows as that preset again.
      if (typedInterval) view.drafts.delete(intervalKeys(input.dataset.playlist).menu);
    });
    // A refused typed interval stays in its field next to the error.
    if (!typedInterval) view.drafts.delete(draftKey);
    draw(view);
    return;
  }
  if (!input.dataset.setting && !input.dataset.displaySetting) return;
  let value = input.type === 'checkbox' ? input.checked : input.value;
  if (input.type === 'number' || input.type === 'range') {
    if (!input.checkValidity() || input.value.trim() === '' || !Number.isFinite(Number(input.value))) {
      input.reportValidity();
      return;
    }
    value = Number(value);
    if (input.dataset.setting === 'frameRateCap') value = frameRateCapValue(value, input.max);
  }
  // A <select> always yields a string; numeric settings must reach Swift as numbers.
  if (input.dataset.number !== undefined && typeof value === 'string') {
    if (!Number.isFinite(Number(value))) return;
    value = Number(value);
  }
  if (input.dataset.displaySetting === 'mirrorTarget' && !value) return;
  const key = input.dataset.key;
  view.drafts.set(key, value);
  await perform(view, key, input.dataset.setting ? 'setting' : 'displaySetting', input.dataset.setting ? { key: input.dataset.setting, value } : { displayID: input.dataset.display, key: input.dataset.displaySetting, value }, () => view.drafts.delete(key));
  view.drafts.delete(key);
  draw(view);
}

async function onClick(view, event) {
  const tab = event.target.closest('[data-section]');
  if (tab) {
    view.section = tab.dataset.section;
    draw(view);
    view.container.querySelector('.settings-scroll').scrollTop = 0;
    return;
  }
  const button = event.target.closest('button[data-action]');
  if (!button || button.disabled) return;
  const action = button.dataset.action;
  const args = JSON.parse(button.dataset.args || '{}');
  if (action.startsWith('layout') || ['displayLayoutApply', 'displayLayoutDelete', 'displayCopyWallpaper', 'displaySwapWallpapers'].includes(action)) {
    await displayLayoutClick(view, action, args, () => draw(view), (command, body, after, onError) => perform(view, 'display-layout', command, body, after, onError));
    return;
  }
  if (automationClick(view, action, args, () => draw(view))) return;
  if (action === 'automationSpace' && args.target === null) {
    const restoreFocus = button === document.activeElement;
    let removed = false;
    await perform(view, action, action, args, () => { removed = true; });
    if (removed && restoreFocus) {
      const mode = [...view.container.querySelectorAll('[data-auto-mode]')].find(input => input.dataset.autoMode === args.displayID);
      const next = mode?.closest('details')?.querySelector('[data-action="automationSpace"]:not(:disabled)');
      (next || mode)?.focus();
    }
    return;
  }
  if (action === 'automationRuleRemove') {
    await perform(view, action, action, args, () => {
      if (view.automationEditor?.displayID === args.displayID && view.automationEditor?.id === args.id) view.automationEditor = null;
      view.automationFocus = { displayID: args.displayID };
    });
    restoreAutomationFocus(view);
    return;
  }
  if (action === 'automationClearLocation') {
    await perform(view, action, action, args, () => { view.drafts.delete('solar-latitude'); view.drafts.delete('solar-longitude'); });
    return;
  }
  // Native opens the share menu next to the button.
  if (action === 'shareApp') {
    const box = button.getBoundingClientRect();
    await perform(view, action, action, { rect: { x: box.x, y: box.y, width: box.width, height: box.height } });
    return;
  }
  if (action === 'playlistMove') {
    await movePlaylistItem(view, args, (displayID, ids, expectedIDs, id) => submitPlaylistOrder(view, displayID, ids, expectedIDs, id));
    return;
  }
  if (action === 'openPerformance') {
    view.section = 'performance';
    draw(view);
    view.container.querySelector('.settings-scroll').scrollTop = 0;
    view.container.querySelector('[data-section="performance"]')?.focus();
    return;
  }
  if (action === 'resetTheme') {
    for (const draftKey of [...view.drafts.keys()]) if (draftKey.startsWith('theme-')) view.drafts.delete(draftKey);
    await perform(view, 'theme-reset', 'resetTheme', {});
    return;
  }
  if (action === 'chooseDisplayWallpaper') {
    await perform(view, 'choose-display', 'target', { id: args.displayID }, async () => {
      await view.helpers.send('navigate', { page: 'installed' });
    });
    return;
  }
  if (action === 'hotkeyRecord') {
    view.recording = String(args.id);
    draw(view);
    view.container.querySelector(`[data-key="hotkey-${view.recording}"] button`)?.focus();
    return;
  }
  if (action === 'hotkeyCancel') { view.recording = null; draw(view); return; }
  view.recording = null;
  // Inline name fields and two-step deletes are page state until their form or button sends.
  if (action === 'editBegin') {
    view.editor = { key: String(args.key), name: String(args.name ?? '') };
    view.armed = '';
    draw(view);
    view.container.querySelector(`[data-editor="${CSS.escape(view.editor.key)}"]`)?.focus();
    return;
  }
  if (action === 'editCancel') { endEditing(view); draw(view); return; }
  if (action === 'arm') {
    view.armed = String(args.key);
    endEditing(view);
    draw(view);
    view.container.querySelector(`[data-key="confirm-${CSS.escape(view.armed)}"] .settings-destructive`)?.focus();
    return;
  }
  if (action === 'disarm') { view.armed = ''; draw(view); return; }
  if (view.armed && view.armed === `plan-delete-${args.planID}`) view.armed = '';
  if (action === 'requestSceneAssets') { await view.helpers.requestAssets(button); return; }
  if (action === 'openSceneDialog') { view.helpers.openDownloadDialog('scene-assets', button); return; }
  if (action === 'openWelcome') { view.helpers.openWelcome(); return; }
  await perform(view, action, action, args);
}

function endEditing(view) {
  if (view.editor) view.drafts.delete(`editor-${view.editor.key}`);
  view.editor = null;
}

// An inline name form carries the native action and its arguments; the typed name joins them.
// The browser's own required-field check runs first, so an empty name never gets this far.
async function onSubmit(view, event) {
  const form = event.target;
  if (form.dataset.form === 'display-layout') {
    event.preventDefault();
    await displayLayoutSubmit(view, form, () => draw(view), (command, body, after, onError) => perform(view, 'display-layout', command, body, after, onError));
    return;
  }
  if (['automation-rule', 'solar-location'].includes(form.dataset.form)) {
    event.preventDefault();
    await automationSubmit(view, form, (action, args, after) => perform(view, action, action, args, after));
    draw(view);
    restoreAutomationFocus(view);
    return;
  }
  if (form.dataset.form !== 'name') return;
  event.preventDefault();
  const name = String(form.elements.name?.value || '').trim();
  const key = form.dataset.editorKey;
  if (!name || !key || view.pending.has(key)) return;
  const args = { ...JSON.parse(form.dataset.args || '{}'), name };
  await perform(view, key, form.dataset.action, args, () => { if (view.editor?.key === key) endEditing(view); });
  draw(view);
}

async function submitPlaylistOrder(view, displayID, ids, expectedIDs, id) {
  const focused = document.activeElement;
  const restore = focused?.closest('[data-playlist-item]')?.dataset.playlistItem === id;
  const direction = restore ? JSON.parse(focused.dataset.args || '{}').direction : null;
  await perform(view, `playlist-order-${displayID}`, 'playlistReorder', { displayID, ids, expectedIDs }, () => {
    const library = new Map((view.state.wallpapers || []).map(item => [item.id, item.title]));
    const visible = ids.filter(item => library.has(item));
    view.playlistAnnouncement = { displayID, text: t('{title} moved to position {position} of {count}.',
      { title: library.get(id) || id, position: visible.indexOf(id) + 1, count: visible.length }) };
  });
  if (restore) {
    const row = [...view.container.querySelectorAll('[data-playlist-item]')].find(row => row.dataset.playlistDisplay === displayID && row.dataset.playlistItem === id);
    const buttons = [...(row?.querySelectorAll('button:not(:disabled)') || [])];
    const same = buttons.find(button => button.dataset.action === 'playlistMove' && JSON.parse(button.dataset.args || '{}').direction === direction);
    (same || buttons[0])?.focus();
  }
}

function playlistFailures(ctx, displayID, playlist, off) {
  const skipped = playlist.skipped || [];
  if (!skipped.length) return '';
  const { state, e, disclosure, button } = ctx;
  const titles = new Map((state.wallpapers || []).map(item => [item.id, item.title]));
  const details = skipped.map(item => `<li><strong>${e(titles.get(item.id) || item.id)}</strong><span class="settings-note">${e(item.message)}</span></li>`).join('');
  return disclosure(`playlist-skipped-${displayID}`, t('Temporarily skipped ({count})', { count: skipped.length }),
    `<p class="settings-note">${e(t('Failed wallpapers are skipped for 15 minutes. You can still apply one manually.'))}</p><ul class="settings-list">${details}</ul>${button(t('Allow these wallpapers again'), 'playlistClearFailures', { displayID }, off)}`);
}

async function perform(view, key, action, args, after, onError) {
  if (view.pending.has(key)) return;
  view.pending.add(key);
  view.error = '';
  draw(view);
  try {
    const state = await view.helpers.send(action, args);
    if (state) view.state = state;
    if (after) await after();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (onError) onError(message); else view.error = message;
  } finally {
    view.pending.delete(key);
    draw(view);
  }
}

function bytes(value) {
  if (!Number.isFinite(value)) return t('Unavailable');
  if (value < 1024) return `${value} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let size = value / 1024;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) { size /= 1024; unit++; }
  return `${size.toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[unit]}`;
}
