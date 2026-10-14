import { t } from './i18n.js';
import { qualityPresets, qualityPresetLabels, activeQualityPreset, frameRateCapSlider, frameRateCapValue, frameRateCapReadout } from './settings.js';

// First-run guide: six full-window pages shown once per Mac, and again on request from
// Settings → Library & Steam. Language, appearance and the lock screen apply the moment they
// are chosen (Skip puts back what was there when the guide opened); the performance choices and
// the other preferences are drafts committed by Continue; the Steam page runs a sign-in-only
// SteamCMD session through the same job pipeline as a download, so Steam's own password and
// Steam Guard prompts are answered right here. The password never leaves this module except as
// the answer to Steam's password prompt.
export const SIGN_IN_ID = 'steam-sign-in';
const STEPS = [
  ['language', 'Language & appearance'],
  ['steam', 'Steam'],
  ['performance', 'Performance'],
  ['preferences', 'Preferences'],
  ['tips', 'Tips'],
  ['start', 'Start'],
];
const stepIndex = key => STEPS.findIndex(([id]) => id === key);
const PRESET_NOTES = {
  low: 'Up to 30 fps at half resolution. Uses the least energy.',
  medium: 'Up to 60 fps at 75% resolution.',
  high: 'No frame-rate limit, full resolution. The default.',
};
const PREFERENCES = [
  ['launchAtLogin', 'power', 'Launch at login', 'Wallpapers come back on their own after a restart.'],
  ['keepWindowsOnWallpaperClick', 'mousePointerClick', 'Keep windows in place when clicking the wallpaper', 'Turns off macOS’s “Click wallpaper to reveal desktop” so clicks reach interactive wallpapers.'],
  ['telemetry', 'activity', 'Send performance data', 'Sends load times, frame rate, energy use and your Mac’s model once a day, to find what makes wallpapers slow. No names, files or account details.'],
];
const BATTERY_MODES = [['keepRunning', 'Keep running'], ['reducedQuality', 'Reduced quality'], ['pause', 'Pause']];
const TIPS = [
  ['search', 'Browse wallpapers in Discover. No account needed.'],
  ['download', 'Download one, then double-click it to apply.'],
  ['monitor', 'Each display plays its own wallpaper. Pick the display in the top bar.'],
];
const STEAM_JOIN_URL = 'https://store.steampowered.com/join/';
const STEAM_STORE_URL = 'https://store.steampowered.com/app/431960/Wallpaper_Engine/';
const ACCOUNT_PATTERN = /^[a-z0-9_]+$/i;

export function createWelcome(helpers) {
  const { container, send, run, escapeHTML: e, icon, button, morph, busy } = helpers;
  let open = false;
  let decided = false;
  let step = 0;
  // Whether the Preferences page, with the performance data switch, has been on screen.
  let preferencesShown = false;
  let state = null;
  // What the guide found when it opened, so Skip can put back the choices that apply at once.
  let initial = null;
  // Sign-in draft. `secret` is held only between Sign in and Steam's password prompt.
  const signIn = { account: '', remember: true, secret: null, reveal: false };
  // A finished sign-in job stays in the downloads list; once the user signs out it no longer counts.
  let dismissedJob = false;
  let setupRequested = false;
  const prefs = new Map();
  // Performance drafts: `frameRateCap` (null is no limit) and `renderScale`, as Settings sends them.
  const perf = new Map();
  const pending = new Set();
  let error = '';
  let lastStepRendered = -1;
  let lastSteamFocusKey = null;

  const signInJob = () => (state?.downloads || []).find(item => item.id === SIGN_IN_ID) || null;
  const signInRequest = () => (state?.downloadRequests || []).find(item => item.id === SIGN_IN_ID) || null;
  const signedIn = () => {
    const job = signInJob();
    if (job?.pending || signInRequest()) return '';
    if (job && !dismissedJob) return !job.error && !job.cancelled ? job.account : '';
    return state?.savedAccount || '';
  };
  const languageOptions = () => [['system', t('System (Auto)'), t('Follows the macOS language')], ...((state?.language?.options || []).map(option => [option.id, option.name, '']))];
  const themeMode = () => state?.theme?.mode || window.__appTheme?.mode || 'system';
  const languageValue = () => state?.language?.preference || 'system';
  const lockScreenValue = () => Boolean(state?.settings?.lockScreenEnabled);
  const snapshotInitial = () => ({ mode: themeMode(), language: languageValue(), lockScreen: lockScreenValue() });
  const navigationBusy = () => pending.has('language') || pending.has('theme') || pending.has('performance') || pending.has('preferences') || pending.has('lockScreen');

  function isOpen() { return open; }
  function openGuide() {
    if (open) return;
    open = true;
    step = 0;
    error = '';
    lastStepRendered = -1;
    lastSteamFocusKey = null;
    prefs.clear();
    perf.clear();
    signIn.secret = null;
    signIn.reveal = false;
    signIn.remember = state?.rememberSession ?? true;
    if (!signIn.account) signIn.account = state?.account || '';
    setupRequested = false;
    initial = state ? snapshotInitial() : null;
    helpers.closePopover?.(false);
    render(state);
  }
  function openIfUndecided() { if (!decided) openGuide(); }
  function close() {
    if (!open) return;
    open = false;
    decided = true;
    signIn.secret = null;
    render(state);
    // Native counts the performance data question as asked only if its switch was on screen.
    if (state?.welcomeSeen === false) run(send('welcomeSeen', { preferencesShown }));
  }
  function go(next) {
    if (navigationBusy()) return;
    step = Math.max(0, Math.min(STEPS.length - 1, next));
    if (step === stepIndex('preferences')) preferencesShown = true;
    error = '';
    render(state);
  }

  async function perform(key, action, args = {}) {
    if (pending.has(key)) return null;
    pending.add(key);
    error = '';
    render(state);
    try {
      return await send(action, args);
    } catch (failure) {
      error = failure?.message || String(failure);
      // The panel's own banner sits behind the guide; the message is shown here instead.
      helpers.clearError?.();
      return null;
    } finally {
      pending.delete(key);
      render(state);
    }
  }

  function render(next) {
    state = next ?? state;
    container.hidden = !open;
    helpers.setBackgroundInert(open);
    if (!open || !state) return;
    if (!initial) initial = snapshotInitial();
    driveSignIn();
    const focused = document.activeElement;
    const previousTitle = container.querySelector('#welcome-title');
    const job = signInJob();
    const request = signInRequest();
    const done = signedIn();
    const steamFocusKey = JSON.stringify([request?.stage, job?.pending, job?.queued, job?.prompt, job?.challenge, done, job?.error, job?.cancelled, error]);
    morph(container, shell());
    if (lastStepRendered !== step) {
      lastStepRendered = step;
      const target = container.querySelector('.welcome-page input:not([disabled]):not([type="checkbox"]):not([type="range"])') || container.querySelector('#welcome-title');
      target?.focus({ preventScroll: false });
      container.querySelector('.welcome-body')?.scrollTo(0, 0);
    } else if (step === 1 && steamFocusKey !== lastSteamFocusKey) {
      const focusLost = !focused?.isConnected || focused.disabled || focused === document.body || focused === previousTitle;
      const atRest = document.activeElement === document.body || document.activeElement === container.querySelector('#welcome-title');
      if (focusLost && atRest) {
        const target = job?.pending && !job.queued && job.prompt ? container.querySelector('#welcome-response')
          : (job?.error || error) && container.querySelector('[data-form="signIn"]') ? container.querySelector('#welcome-password')
            : done ? container.querySelector('.welcome-footer .welcome-continue')
              : request || job?.pending ? container.querySelector('#welcome-title') : null;
        target?.focus({ preventScroll: false });
      }
    }
    lastSteamFocusKey = steamFocusKey;
  }

  // Steam's password prompt is answered with the held secret exactly once; anything else
  // Steam asks (Steam Guard code, mobile approval) is put in front of the user.
  function driveSignIn() {
    const job = signInJob();
    if (!job?.pending) { if (job && signIn.secret) signIn.secret = null; return; }
    if (job.prompt && job.securePrompt && signIn.secret && !busy('downloadInput', { id: job.id })) {
      const value = signIn.secret;
      signIn.secret = null;
      run(send('downloadInput', { id: job.id, value }));
    }
  }

  function shell() {
    const done = signedIn();
    const job = signInJob();
    const needsAttention = job?.pending && !job.queued && (job.prompt || job.challenge) && !busy('downloadInput', { id: job.id }) && !(job.securePrompt && signIn.secret);
    const progress = STEPS.map(([key, label], index) => {
      const attention = index === 1 && step !== 1 && needsAttention;
      const name = attention ? t('{summary} · needs attention', { summary: t(label) }) : t(label);
      return `<li data-key="progress-${key}"><button type="button" data-action="go" data-step="${index}" class="welcome-step${index === step ? ' current' : index < step ? ' done' : ''}${attention ? ' attention' : ''}" aria-label="${e(name)}" title="${e(name)}"${index === step ? ' aria-current="step"' : ''}${navigationBusy() ? ' disabled' : ''}><span class="welcome-step-dot" aria-hidden="true">${attention ? icon('shield', 11) : index < step ? icon('check', 11) : ''}</span><span class="welcome-step-label">${e(t(label))}</span></button></li>`;
    }).join('');
    const pages = [pageLanguage, pageSteam, pagePerformance, pagePreferences, pageTips, pageStart];
    return `<div class="welcome-bar" data-key="bar"><ol class="welcome-progress" aria-label="${e(t('Setup progress'))}">${progress}</ol></div><div class="welcome-body" data-key="body"><section class="welcome-page" data-key="page-${step}" data-step="${STEPS[step][0]}" aria-labelledby="welcome-title">${pages[step](done)}</section></div><div class="welcome-footer" data-key="footer"><div class="welcome-footer-row">${footer(done)}</div></div>`;
  }

  function footer(done) {
    const back = step > 0 ? button(t('Back'), 'back', {}, { icon: 'chevronLeft', className: 'quiet', disabled: navigationBusy() }) : '<span></span>';
    const next = (label, action, extra = {}) => button(label, action, {}, { icon: 'arrowRight', className: 'primary welcome-continue', ...extra });
    switch (STEPS[step][0]) {
      case 'language': return `${back}<span class="welcome-footer-actions">${button(t('Skip'), 'skipLanguage', {}, { className: 'quiet', disabled: pending.size > 0 })}${next(t('Continue'), 'continue', { disabled: pending.size > 0 })}</span>`;
      case 'steam': {
        const job = signInJob();
        const running = Boolean(job?.pending || signInRequest());
        return `${back}<span class="welcome-footer-actions">${done ? next(t('Continue'), 'continue') : button(running ? t('Skip and cancel sign-in') : t('Skip for now'), 'skipSteam', {}, { className: 'quiet' })}</span>`;
      }
      case 'performance': return `${back}<span class="welcome-footer-actions">${button(t('Skip'), 'skipPerformance', {}, { className: 'quiet', disabled: navigationBusy() })}${next(t('Continue'), 'savePerformance', { disabled: navigationBusy() })}</span>`;
      case 'preferences': return `${back}<span class="welcome-footer-actions">${button(t('Skip'), 'skipPreferences', {}, { className: 'quiet', disabled: navigationBusy() })}${next(t('Continue'), 'savePreferences', { disabled: navigationBusy() })}</span>`;
      case 'tips': return `${back}<span class="welcome-footer-actions">${next(t('Continue'), 'continue')}</span>`;
      default: return `${back}<span class="welcome-footer-actions">${button(t('Start using the app'), 'finish', {}, { icon: 'check', className: 'primary welcome-continue' })}</span>`;
    }
  }

  const head = (title, lead) => `<header class="welcome-head"><h1 id="welcome-title" tabindex="-1">${e(title)}</h1>${lead ? `<p class="welcome-lead">${e(lead)}</p>` : ''}</header>`;
  const option = (action, value, checked, body, off, focusable = checked) => `<button type="button" role="radio" aria-checked="${checked}" tabindex="${focusable ? '0' : '-1'}" data-action="${action}" data-value="${e(value)}" class="welcome-option" data-key="${action}-${e(value)}"${off ? ' disabled' : ''}>${body}<span class="welcome-option-check" aria-hidden="true">${icon('check', 13)}</span></button>`;

  function pageLanguage() {
    const languageBusy = pending.has('language');
    const themeBusy = pending.has('theme');
    const language = languageOptions().map(([id, name, note]) => option('language', id, id === languageValue(), `<span class="welcome-option-title">${e(name)}</span>${note ? `<span class="welcome-option-note">${e(note)}</span>` : ''}`, languageBusy)).join('');
    const appearance = [['system', 'sunMoon', 'System (Auto)', 'Follows macOS light and dark'], ['light', 'sun', 'Light', ''], ['dark', 'moon', 'Dark', '']]
      .map(([id, glyph, title, note]) => option('theme', id, id === themeMode(), `<span class="welcome-swatch" data-appearance="${id}" aria-hidden="true"><span></span></span><span class="welcome-option-title">${icon(glyph, 14)}${e(t(title))}</span>${note ? `<span class="welcome-option-note">${e(t(note))}</span>` : ''}`, themeBusy)).join('');
    return `<div class="welcome-brand" aria-hidden="true">${icon('wallpaperMachine', 48)}</div>${head(t('Welcome to WallpaperMachine'), t('Use Steam Workshop wallpapers on your Mac desktop. Choose a language and appearance to start. You can change both later in Settings.'))}
      <fieldset class="welcome-choice"><legend>${icon('languages', 15)}${e(t('Language'))}</legend><div class="welcome-options welcome-languages" role="radiogroup" aria-label="${e(t('Language'))}">${language}</div><p class="welcome-note">${e(t('The interface and import picker switch at once. Quit and reopen the app to switch menus and other dialogs.'))}</p></fieldset>
      <fieldset class="welcome-choice"><legend>${icon('sunMoon', 15)}${e(t('Appearance'))}</legend><div class="welcome-options" role="radiogroup" aria-label="${e(t('Appearance'))}">${appearance}</div></fieldset>
      ${error ? `<p class="notice error" role="alert">${e(error)}</p>` : ''}`;
  }

  function pageSteam(done) {
    const job = signInJob();
    const request = signInRequest();
    const setup = state.setup || {};
    const lead = t('You can browse without an account. Steam Workshop downloads require an account that owns Wallpaper Engine. Sign in now, or skip and sign in at your first download.');
    const links = `<div class="welcome-steam-links"><div class="welcome-steam-link"><p><b>${e(t('No Steam account yet?'))}</b> ${e(t('Creating one is free.'))}</p>${button(t('Create a Steam account'), 'openExternal', { url: STEAM_JOIN_URL }, { icon: 'external', className: 'link' })}</div><div class="welcome-steam-link"><p><b>${e(t('Don’t own Wallpaper Engine?'))}</b> ${e(t('It is a one-time purchase on Steam.'))}</p>${button(t('Buy Wallpaper Engine'), 'openExternal', { url: STEAM_STORE_URL }, { icon: 'external', className: 'link' })}</div></div>`;
    let body;
    if (done) {
      const ownership = !dismissedJob && job?.account === done ? job.wallpaperEngineOwnership : 'unknown';
      const owned = ownership === 'owned';
      const missing = ownership === 'notOwned';
      const message = owned
        ? t('Wallpaper Engine ownership confirmed. You can download its Workshop wallpapers.')
        : missing
          ? t('This Steam account does not own Wallpaper Engine. Please purchase it on Steam to download Wallpaper Engine wallpapers. You can still download from Pixiv, browse the Workshop, and view Wallpaper Engine wallpapers you already have.')
          : t('Wallpaper Engine ownership has not been confirmed. Check again to verify this account can download its Workshop wallpapers. You can still download from Pixiv, browse the Workshop, and view wallpapers you already have.');
      const purchase = missing ? button(t('Buy Wallpaper Engine'), 'openExternal', { url: STEAM_STORE_URL }, { icon: 'external', className: 'primary' }) : '';
      const recheck = !owned ? button(t('Check ownership again'), 'checkOwnership', {}, { className: 'quiet', disabled: pending.has('signIn') }) : '';
      body = statusCard(owned ? 'check' : 'info', t('Signed in as {account}', { account: done }), message, `${job?.warning ? `<p class="notice warning">${e(job.warning)}</p>` : ''}<div class="welcome-status-actions">${purchase}${recheck}${button(t('Use a different account'), 'signOut', {}, { className: 'link', disabled: busy('logOutSteam') })}</div>${error ? `<p class="notice error" role="alert">${e(error)}</p>` : ''}`, owned ? 'success' : '');
    } else if (request) {
      body = setupCard(request, setup);
    } else if (job?.pending) {
      body = signingInCard(job);
    } else {
      body = signInForm(job, setup);
    }
    return `${head(t('Sign in to Steam'), lead)}${body}${done ? '' : links}`;
  }

  const statusCard = (glyph, title, text, extra = '', tone = '') => `<section class="welcome-status${tone ? ` ${tone}` : ''}" data-key="status" aria-live="polite"><span class="dialog-guide-icon">${icon(glyph, 20)}</span><div class="welcome-status-body"><p class="welcome-status-title">${e(title)}</p>${text ? `<p class="welcome-status-text">${e(text)}</p>` : ''}${extra}</div></section>`;

  function setupCard(request, setup) {
    const stage = request.stage;
    if (stage === 'setup') {
      const progress = setup.busy ? `<progress max="1"${Number.isFinite(setup.progress) ? ` value="${Math.max(0, Math.min(1, setup.progress))}"` : ''} aria-label="${e(t('SteamCMD installation progress'))}"></progress>` : '';
      // Installation normally starts with the sign-in; a guide reopened on a waiting request, or
      // a failed install, gets the same two ways forward as Settings.
      const actions = setup.canApprove
        ? button(t('Allow this SteamCMD'), 'setupApprove', {}, { icon: 'shield', className: 'primary' })
        : !setup.busy ? `${button(setup.error ? t('Try again') : t('Install SteamCMD'), 'setupInstall', {}, { icon: setup.error ? 'refresh' : 'download', className: 'primary' })}${button(t('Locate a copy'), 'setupLocate', {}, { icon: 'folder' })}` : '';
      const text = setup.canApprove ? t('macOS needs your approval before this downloaded copy of SteamCMD can run. Only this exact copy is allowed.') : t('SteamCMD is Valve’s free download tool. It is being installed into this app’s own folder; the sign-in follows on its own.');
      return statusCard('download', setup.status || t('Installing SteamCMD…'), text, `${progress}${setup.error ? `<p class="notice error" role="alert">${e(setup.error)}</p>` : ''}<div class="welcome-status-actions">${actions}${button(t('Cancel'), 'cancelSignIn', {}, { className: 'quiet' })}</div>`);
    }
    // `account`: the downloader refused the name; the form returns with the reason.
    return signInForm(null, setup);
  }

  function signingInCard(job) {
    const account = job.account || signIn.account;
    if (!job.queued && !job.authenticating && !job.prompt && !job.challenge) return statusCard('search', t('Checking Wallpaper Engine ownership…'), '', `<progress aria-label="${e(t('Checking Wallpaper Engine ownership…'))}"></progress><div class="welcome-status-actions">${button(t('Cancel'), 'cancelSignIn', {}, { className: 'quiet' })}</div>`);
    if (job.queued) return statusCard('logIn', job.status, t('The sign-in starts as soon as the current download is done.'), `<progress aria-label="${e(t('Waiting'))}"></progress><div class="welcome-status-actions">${button(t('Cancel'), 'cancelSignIn', {}, { className: 'quiet' })}</div>`);
    const guide = helpers.signInGuide(job, account);
    const cancel = button(t('Cancel'), 'cancelSignIn', {}, { className: 'quiet', disabled: busy('downloadCancel', { id: job.id }) });
    if (job.prompt) {
      const working = busy('downloadInput', { id: job.id });
      const secure = Boolean(job.securePrompt);
      const help = guide?.phone ? button(t('Get the Steam mobile app'), 'openExternal', { url: 'https://store.steampowered.com/mobile' }, { icon: 'external', className: 'link' }) : guide?.mail ? button(t('Help with emailed codes'), 'openExternal', { url: 'https://help.steampowered.com/en/wizard/HelpWithSteamGuardCode' }, { icon: 'external', className: 'link' }) : '';
      const explain = secure ? statusCard('lock', t('Steam asks for your password'), t('Enter it below. It goes straight to Steam and is never stored by this app.')) : guide ? helpers.guideMarkup(guide) : '';
      return `${explain}<form class="welcome-form" data-form="prompt" data-id="${e(job.id)}" data-key="prompt-${e(job.prompt)}"><label class="field" for="welcome-response">${e(t(job.prompt))}<input id="welcome-response" name="response" type="${secure ? 'password' : 'text'}" autocomplete="${secure ? 'current-password' : 'one-time-code'}" spellcheck="false" autocapitalize="off" required${working ? ' disabled' : ''}></label><div class="welcome-form-actions"><button type="submit" class="primary"${working ? ' disabled' : ''}>${icon(secure ? 'lock' : 'keyRound')}<span class="button-label">${e(t('Submit'))}</span></button>${cancel}${help}</div></form>`;
    }
    if (job.challenge) {
      return `${helpers.guideMarkup(guide, `<progress aria-label="${e(t('Waiting for Steam'))}"></progress>`)}<div class="welcome-status-actions">${cancel}${guide?.phone ? button(t('Get the Steam mobile app'), 'openExternal', { url: 'https://store.steampowered.com/mobile' }, { icon: 'external', className: 'link' }) : ''}</div>`;
    }
    return statusCard('logIn', job.status || t('Contacting Steam…'), t('Password and Steam Guard prompts appear here.'), `<progress aria-label="${e(t('Connecting to Steam'))}"></progress><div class="welcome-status-actions">${cancel}</div>`);
  }

  function signInForm(job, setup) {
    const working = pending.has('signIn');
    const failure = error || job?.error || (job?.cancelled ? t('The sign-in was cancelled.') : '');
    const label = setup.ready ? t('Sign in') : t('Install SteamCMD and sign in');
    return `<form class="welcome-form" data-form="signIn" data-key="sign-in-form" novalidate>
      <label class="field" for="welcome-account">${e(t('Steam account name'))}<input id="welcome-account" name="account" type="text" autocomplete="username" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="${e(t('The name you log in with'))}" value="${e(signIn.account)}"${working ? ' disabled' : ''}><span class="welcome-field-note">${e(t('Your login name, not the profile name other players see.'))}</span></label>
      <label class="field" for="welcome-password">${e(t('Password'))}<span class="welcome-password"><input id="welcome-password" name="password" type="${signIn.reveal ? 'text' : 'password'}" autocomplete="current-password" spellcheck="false" autocapitalize="off" data-key="password"${working ? ' disabled' : ''}>${button('', 'reveal', {}, { icon: signIn.reveal ? 'eyeOff' : 'eye', title: signIn.reveal ? t('Hide password') : t('Show password'), className: 'quiet icon-button', disabled: working })}</span></label>
      <label class="check-label welcome-remember" data-key="remember"><input type="checkbox" name="remember"${signIn.remember ? ' checked' : ''}${working ? ' disabled' : ''}><span>${e(t('Keep me signed in on this Mac'))}<span class="welcome-field-note">${e(t('Keeps you signed in to Steam on this Mac so downloads don’t ask again. Your password is not saved.'))}</span></span></label>
      ${failure ? `<p class="notice error" role="alert">${e(failure)}</p>` : ''}
      <div class="welcome-form-actions"><button type="submit" class="primary"${working ? ' disabled' : ''}>${icon('logIn')}<span class="button-label">${e(label)}</span></button></div>
      <p class="welcome-note">${e(setup.ready ? t('Your password goes straight to Valve’s SteamCMD and is never stored by this app. Steam Guard requests appear here.') : t('SteamCMD is Valve’s free download tool. It is installed into this app’s own folder the first time. Your password goes straight to it and is never stored by this app.'))}</p>
    </form>`;
  }

  function committedPerformance(key) {
    const settings = state.settings || {};
    if (key === 'renderScale') return Number(settings.preferredRenderScale ?? 1);
    return settings.frameRateCap ?? null;
  }
  const performanceValue = key => perf.has(key) ? perf.get(key) : committedPerformance(key);
  const performanceChanged = ([key, value]) => key === 'renderScale' ? Math.abs(value - committedPerformance(key)) > 0.001 : value !== committedPerformance(key);
  function pagePerformance() {
    const settings = state.settings;
    const unavailable = !settings;
    const off = unavailable || pending.has('performance');
    const draft = { frameRateCapMax: settings?.frameRateCapMax, frameRateCap: performanceValue('frameRateCap'), preferredRenderScale: performanceValue('renderScale') };
    const active = unavailable ? null : activeQualityPreset(draft);
    // A radio group needs one tab stop; with no preset matching, the first one takes it.
    const presets = qualityPresetLabels.map(([id, label], index) => option('preset', id, id === active, `<span class="welcome-option-title">${e(t(label))}</span><span class="welcome-option-note">${e(t(PRESET_NOTES[id]))}</span>`, off, id === active || (active === 'custom' && index === 0))).join('');
    const slider = frameRateCapSlider(draft);
    const limit = `<div class="welcome-range"><input id="welcome-frame-rate" type="range" data-performance="frameRateCap" min="10" max="${slider.max}" step="1" value="${slider.value}" aria-label="${e(t('Frame rate limit'))}"${off ? ' disabled' : ''}><output for="welcome-frame-rate" data-performance-readout>${e(frameRateCapReadout(slider.value, slider.max))}</output></div>`;
    return `${head(t('Performance'), t('Choose how smoothly wallpapers run and how much energy they use. You can change this later in Settings › Performance.'))}${unavailable ? `<p class="notice">${e(t('Settings are unavailable right now. You can set these later in Settings.'))}</p>` : ''}
      <fieldset class="welcome-choice"><legend>${icon('slidersVertical', 15)}${e(t('Quality preset'))}</legend><div class="welcome-options" role="radiogroup" aria-label="${e(t('Quality preset'))}">${presets}</div>${active === 'custom' ? `<p class="welcome-note">${e(t('Custom: the frame-rate limit and render scale match none of the presets.'))}</p>` : ''}</fieldset>
      <fieldset class="welcome-choice"><legend>${icon('monitor', 15)}${e(t('Frame rate limit'))}</legend>${limit}<p class="welcome-note">${e(t('At the top of the slider there is no limit, and each display runs at up to 60 fps unless you choose more for it. A lower limit saves energy.'))}</p></fieldset>
      ${error ? `<p class="notice error" role="alert">${e(error)}</p>` : ''}`;
  }

  function committedPreference(key) {
    if (key === 'batteryMode') return state.settings?.batteryMode || 'keepRunning';
    return Boolean(state.settings?.[key]);
  }
  function pagePreferences() {
    const settings = state.settings;
    const unavailable = !settings;
    const toggle = ([key, glyph, title, note]) => {
      const off = unavailable || pending.has('preferences') || (key === 'launchAtLogin' && !settings?.launchAtLoginAvailable)
        || (key === 'telemetry' && !settings?.telemetryAvailable);
      const value = prefs.has(key) ? prefs.get(key) : Boolean(settings?.[key]);
      // Switched off in System Settings, the login item stays off until the user allows it there.
      const extra = key !== 'launchAtLogin' || !settings ? ''
        : !settings.launchAtLoginAvailable ? ` ${t('Move the app to Applications to enable.')}`
        : settings.launchAtLoginNeedsApproval ? ` ${t('Allow WallpaperMachine in System Settings → General → Login Items to launch it at login.')}` : '';
      return `<label class="welcome-pref" data-key="pref-${key}"><span class="dialog-guide-icon">${icon(glyph, 18)}</span><span class="welcome-pref-body"><span class="welcome-pref-title">${e(t(title))}</span><span class="welcome-pref-note">${e(t(note))}${e(extra)}</span></span><span class="settings-switch"><input type="checkbox" role="switch" data-pref="${key}" aria-label="${e(t(title))}"${value ? ' checked' : ''}${off ? ' disabled' : ''}><span aria-hidden="true"></span></span></label>`;
    };
    const battery = prefs.has('batteryMode') ? prefs.get('batteryMode') : (settings?.batteryMode || 'keepRunning');
    const batteryOff = unavailable || pending.has('preferences');
    const batteryRow = `<label class="welcome-pref" data-key="pref-batteryMode"><span class="dialog-guide-icon">${icon('batteryCharging', 18)}</span><span class="welcome-pref-body"><span class="welcome-pref-title">${e(t('On battery'))}</span><span class="welcome-pref-note">${e(t('Keep wallpapers running, lower their quality, or pause them while on battery.'))}</span><select data-pref="batteryMode" aria-label="${e(t('On battery'))}"${batteryOff ? ' disabled' : ''}>${BATTERY_MODES.map(([id, label]) => `<option value="${id}"${battery === id ? ' selected' : ''}>${e(t(label))}</option>`).join('')}</select></span></label>`;
    const rows = `${toggle(PREFERENCES[0])}${batteryRow}${toggle(PREFERENCES[1])}${toggle(PREFERENCES[2])}`;
    return `${head(t('A few preferences'), t('You can change these later in Settings.'))}${unavailable ? `<p class="notice">${e(t('Settings are unavailable right now. You can set these later in Settings.'))}</p>` : ''}<div class="welcome-prefs">${rows}${lockScreenRow(settings)}</div>${settings?.lockScreenError ? `<p class="notice error" role="alert">${e(settings.lockScreenError)}</p>` : ''}${error ? `<p class="notice error" role="alert">${e(error)}</p>` : ''}`;
  }

  // Unlike the rows above, the lock screen is not a draft: it applies at once, like Settings.
  function lockScreenRow(settings) {
    const unavailable = !settings || settings.lockScreenAvailable === false || settings.lockScreenStatus == null;
    const working = pending.has('lockScreen') || Boolean(settings?.lockScreenBusy);
    const status = settings?.lockScreenStatus || t('Updating');
    const note = unavailable ? (settings?.lockScreenAvailable === false && settings.lockScreenStatus) || t('Unavailable') : working ? (status.endsWith('…') ? status : `${status}…`) : t('Experimental. Applies right away.');
    const off = unavailable || working || pending.has('preferences');
    return `<label class="welcome-pref" data-key="pref-lockScreen"><span class="dialog-guide-icon">${icon('lock', 18)}</span><span class="welcome-pref-body"><span class="welcome-pref-title">${e(t('Animate lock screen'))}</span><span class="welcome-pref-note">${e(note)}</span></span><span class="settings-switch"><input type="checkbox" role="switch" data-lock-screen aria-label="${e(t('Animate lock screen'))}"${lockScreenValue() ? ' checked' : ''}${off ? ' disabled' : ''}><span aria-hidden="true"></span></span></label>`;
  }

  function pageTips() {
    const repository = helpers.safeLink(state.repositoryURL);
    const tips = TIPS.map(([glyph, text]) => `<li><span class="dialog-guide-icon">${icon(glyph, 18)}</span><p>${e(t(text))}</p></li>`).join('');
    // Names the inspector's report link, which pre-fills the issue with the wallpaper.
    const report = e(t('Videos usually play. Scenes are experimental, and Application wallpapers can’t run on macOS. If one doesn’t work, use “Report on GitHub” in its details. Pull requests are welcome too.'));
    const links = repository ? `<div class="welcome-status-actions">${button(t('Report an issue'), 'openExternal', { url: `${repository.replace(/\/$/, '')}/issues` }, { icon: 'external', className: 'link' })}${button(t('Contribute on GitHub'), 'openExternal', { url: repository }, { icon: 'external', className: 'link' })}</div>` : '';
    const support = `<section class="welcome-support" aria-labelledby="welcome-support-title"><span class="dialog-guide-icon">${icon('github', 18)}</span><div class="welcome-status-body"><p class="welcome-status-title" id="welcome-support-title">${e(t('Not every wallpaper works yet'))}</p><p class="welcome-status-text">${report}</p>${links}</div></section>`;
    return `${head(t('The basics'))}<ol class="welcome-tips">${tips}</ol>${support}`;
  }

  function pageStart(done) {
    const language = languageOptions().find(([id]) => id === languageValue());
    const mode = { system: 'System (Auto)', light: 'Light', dark: 'Dark' }[themeMode()] || 'System (Auto)';
    const job = signInJob();
    const request = signInRequest();
    const waiting = !done && (job?.pending || request);
    const steam = done ? t('Signed in as {account}', { account: done }) : job?.pending ? job.status || t('Waiting for Steam') : request ? request.stage === 'setup' ? state.setup?.status || helpers.stageHint('setup') : helpers.stageHint(request.stage) : t('Not signed in. You’ll be asked at your first download.');
    const unsavedPreferences = [...prefs].filter(([key, value]) => committedPreference(key) !== value).length;
    const unsavedPerformance = [...perf].filter(performanceChanged).length;
    const unsaved = (label, count, key) => count ? `<div><dt>${e(t(label))}</dt><dd>${e(t(count === 1 ? '{count} change not saved' : '{count} changes not saved', { count }))}</dd>${button(t('Review'), 'go', { step: stepIndex(key) }, { className: 'link' })}</div>` : '';
    const recap = `<dl class="welcome-recap"><div><dt>${e(t('Language'))}</dt><dd>${e(language ? language[1] : t('System (Auto)'))}</dd></div><div><dt>${e(t('Appearance'))}</dt><dd>${e(t(mode))}</dd></div><div><dt>${e(t('Steam'))}</dt><dd>${e(steam)}</dd>${waiting ? button(t('Finish sign-in'), 'go', { step: stepIndex('steam') }, { className: 'link' }) : ''}</div>${unsaved('Performance', unsavedPerformance, 'performance')}${unsaved('Preferences', unsavedPreferences, 'preferences')}</dl>`;
    return `${head(t('Setup complete'), t('Your desktop won’t change until you apply a wallpaper.'))}${recap}<div class="welcome-start"><button type="button" class="welcome-start-option" data-action="browse"><span class="dialog-guide-icon">${icon('search', 18)}</span><span class="welcome-pref-body"><span class="welcome-pref-title">${e(t('Browse the Workshop'))}</span><span class="welcome-pref-note">${e(t('Find wallpapers from Steam in Discover.'))}</span></span>${icon('chevronRight', 16)}</button><button type="button" class="welcome-start-option" data-action="import"><span class="dialog-guide-icon">${icon('plus', 18)}</span><span class="welcome-pref-body"><span class="welcome-pref-title">${e(t('Import wallpapers'))}</span><span class="welcome-pref-note">${e(t('Bring in wallpaper folders or files you already have.'))}</span></span>${icon('chevronRight', 16)}</button></div><p class="welcome-note">${e(t('You can open this guide again from Settings → Library & Steam.'))}</p>`;
  }

  // Actions
  async function chooseLanguage(value) {
    if (value === languageValue()) return;
    const focused = document.activeElement;
    const restoreFocus = focused?.matches('.welcome-option[data-action="language"]');
    await perform('language', 'languageSetting', { value: String(value) });
    if (restoreFocus && focused.isConnected && !focused.disabled && document.activeElement === document.body) focused.focus({ preventScroll: true });
  }
  async function chooseTheme(value) {
    if (value === themeMode()) return;
    const focused = document.activeElement;
    const restoreFocus = focused?.matches('.welcome-option[data-action="theme"]');
    await perform('theme', 'themeSetting', { key: 'mode', value: String(value) });
    if (restoreFocus && focused.isConnected && !focused.disabled && document.activeElement === document.body) focused.focus({ preventScroll: true });
  }
  async function skipLanguage() {
    if (initial) {
      if (themeMode() !== initial.mode) await perform('theme', 'themeSetting', { key: 'mode', value: initial.mode });
      if (languageValue() !== initial.language) await perform('language', 'languageSetting', { value: initial.language });
    }
    go(step + 1);
  }
  async function submitSignIn(form) {
    const account = String(form.elements.account.value || '').trim();
    const password = String(form.elements.password.value || '');
    signIn.account = account;
    signIn.remember = Boolean(form.elements.remember.checked);
    if (!account || account.toLowerCase() === 'anonymous' || !ACCOUNT_PATTERN.test(account)) {
      error = t('Enter your Steam account name: the login name, not the profile name. Letters, numbers and underscores only.');
      form.elements.account.focus();
      render(state);
      return;
    }
    if (!password) {
      error = t('Enter your Steam password.');
      form.elements.password.focus();
      render(state);
      return;
    }
    form.elements.password.value = '';
    signIn.secret = password;
    signIn.reveal = false;
    dismissedJob = false;
    setupRequested = false;
    const result = await perform('signIn', 'steamSignIn', { account, rememberSession: signIn.remember });
    if (!result) { signIn.secret = null; return; }
    // Without SteamCMD the request waits at the setup stage; installing it is part of signing in.
    const request = signInRequest();
    const setup = state?.setup || {};
    if (request?.stage === 'setup' && !setup.busy && !setup.ready && !setup.candidatePath && !setupRequested) {
      setupRequested = true;
      await perform('setup', 'setupInstall');
    }
  }
  async function cancelSignIn() {
    signIn.secret = null;
    const job = signInJob();
    const request = signInRequest();
    if (request) {
      await perform('cancel', 'removeDownloadRequest', { id: SIGN_IN_ID });
      if (state?.setup?.busy && setupRequested) await perform('setupCancel', 'setupCancel');
    }
    if (job?.pending) await perform('cancel', 'downloadCancel', { id: job.id });
  }
  async function setLockScreen(input) {
    await perform('lockScreen', 'setting', { key: 'lockScreenEnabled', value: input.checked });
    // A refused change must not leave the switch showing it; a focused input keeps its own state across renders.
    if (input.isConnected) input.checked = lockScreenValue();
  }
  function choosePreset(id) {
    const preset = qualityPresets[id];
    if (!preset) return;
    perf.set('frameRateCap', preset.frameRateCap);
    perf.set('renderScale', preset.renderScale);
    render(state);
  }
  async function skipPreferences() {
    prefs.clear();
    if (initial && lockScreenValue() !== initial.lockScreen) await perform('lockScreen', 'setting', { key: 'lockScreenEnabled', value: initial.lockScreen });
    go(step + 1);
  }
  // Sends each changed draft as the same `setting` Settings uses, then moves on. A refusal stays
  // on the page with its reason; drafts already sent now match what native reports.
  async function commitDrafts(drafts, key, changed) {
    const entries = [...drafts].filter(changed);
    if (!entries.length) { drafts.clear(); go(step + 1); return; }
    pending.add(key);
    render(state);
    try {
      for (const [setting, value] of entries) await send('setting', { key: setting, value });
      drafts.clear();
      pending.delete(key);
      go(step + 1);
    } catch (failure) {
      pending.delete(key);
      error = failure?.message || String(failure);
      helpers.clearError?.();
      render(state);
    }
  }

  container.addEventListener('click', event => {
    const control = event.target.closest('[data-action]');
    if (!control || control.disabled) return;
    const action = control.dataset.action;
    switch (action) {
      case 'go': go(Number(control.dataset.step)); return;
      case 'back': go(step - 1); return;
      case 'continue': go(step + 1); return;
      case 'skipLanguage': run(skipLanguage()); return;
      case 'preset': choosePreset(control.dataset.value); return;
      case 'skipPerformance': perf.clear(); go(step + 1); return;
      case 'savePerformance': run(commitDrafts(perf, 'performance', performanceChanged)); return;
      case 'skipPreferences': run(skipPreferences()); return;
      case 'savePreferences': run(commitDrafts(prefs, 'preferences', ([key, value]) => committedPreference(key) !== value)); return;
      case 'skipSteam': run(cancelSignIn().then(() => go(step + 1))); return;
      case 'language': run(chooseLanguage(control.dataset.value)); return;
      case 'theme': run(chooseTheme(control.dataset.value)); return;
      case 'reveal': signIn.reveal = !signIn.reveal; render(state); container.querySelector('#welcome-password')?.focus(); return;
      case 'cancelSignIn': run(cancelSignIn()); return;
      case 'checkOwnership': {
        const account = signedIn();
        if (!account) return;
        dismissedJob = false;
        run(perform('signIn', 'steamSignIn', { account, rememberSession: signIn.remember }));
        return;
      }
      case 'signOut': run(perform('signOut', 'logOutSteam').then(result => { if (result && !result.savedAccount) dismissedJob = true; render(state); })); return;
      case 'setupApprove': case 'setupInstall': case 'setupLocate': run(perform(action, action)); return;
      case 'openExternal': run(send('openExternal', { url: control.dataset.url })); return;
      case 'browse': close(); run(helpers.navigate('discover')); return;
      case 'import': close(); run(helpers.openImport()); return;
      case 'finish': close(); return;
      default: return;
    }
  });
  container.addEventListener('mousedown', event => {
    // The top strip stands in for the title bar while the guide covers it.
    if (event.button === 0 && event.target.closest('.welcome-bar') && !event.target.closest('button')) { event.preventDefault(); helpers.dragWindow?.(); }
  });
  container.addEventListener('input', event => {
    const element = event.target;
    if (element.name === 'account') signIn.account = element.value;
    if (element.dataset.performance === 'frameRateCap') {
      const readout = container.querySelector('[data-performance-readout]');
      if (readout) readout.textContent = frameRateCapReadout(element.value, element.max);
    }
  });
  container.addEventListener('change', event => {
    const element = event.target;
    if (element.name === 'remember') signIn.remember = element.checked;
    if (element.dataset.pref) { prefs.set(element.dataset.pref, element.dataset.pref === 'batteryMode' ? element.value : element.checked); render(state); }
    if (element.dataset.performance === 'frameRateCap') { perf.set('frameRateCap', frameRateCapValue(element.value, element.max)); render(state); }
    if (element.hasAttribute('data-lock-screen')) run(setLockScreen(element));
  });
  container.addEventListener('submit', event => {
    event.preventDefault();
    const form = event.target;
    if (form.dataset.form === 'signIn') run(submitSignIn(form));
    if (form.dataset.form === 'prompt') {
      const input = form.elements.response;
      const value = input.value;
      if (!value) return;
      // The answer belongs to Steam alone and never survives the submit.
      input.value = '';
      run(send('downloadInput', { id: form.dataset.id, value }));
    }
  });
  container.addEventListener('keydown', event => {
    const control = event.target.closest('.welcome-option');
    if (!control || !['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const options = [...control.parentElement.querySelectorAll('.welcome-option:not([disabled])')];
    const index = options.indexOf(control);
    const next = options[event.key === 'Home' ? 0 : event.key === 'End' ? options.length - 1 : (index + (['ArrowRight', 'ArrowDown'].includes(event.key) ? 1 : -1) + options.length) % options.length];
    next?.focus();
    next?.click();
  });

  return { isOpen, open: openGuide, openIfUndecided, close, render, currentStep: () => step };
}
