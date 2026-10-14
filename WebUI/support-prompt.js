import { t } from './i18n.js';

// The three one-time prompts: support after the first downloaded wallpaper, a later GitHub star
// request, and asking someone who finished the welcome guide before it had the switch whether to
// send performance data. Native owns eligibility, the order and the durable once-only flags, and
// names at most one in `pendingPrompt`. The page acknowledges only a visible dialog, then keeps
// that presentation alive when the acknowledgement clears it.
const CHOICES = {
  support: ['star', 'supporter', 'dismiss'],
  star: ['star', 'dismiss'],
  telemetry: ['enableTelemetry', 'dismiss'],
};

export function createSupportPrompt({ container, send, escapeHTML: e, icon, morph, canPresent, restoreFocus }) {
  let state = null;
  let kind = null;
  const closed = new Set();
  let acknowledged = false;
  let acknowledgementAttempted = false;
  let acknowledgement = null;
  let choosing = false;
  let error = '';
  let previousFocus = null;

  const blocked = () => document.hidden || !canPresent()
    || [...document.querySelectorAll('dialog[open]')].some(dialog => dialog !== container);

  function content(prompt) {
    const off = choosing ? ' disabled' : '';
    const choice = (value, glyph, title, note, external = true) => `<button type="button" class="dialog-choice" data-action="supportPromptChoice" data-choice="${value}"${off}><span class="dialog-guide-icon">${icon(glyph, 20)}</span><span class="dialog-choice-body"><span class="dialog-choice-title">${e(title)}</span><span class="dialog-choice-note">${e(note)}</span></span>${external ? icon('external', 15) : ''}</button>`;
    const copy = {
      support: [t('Feeling good?'), t('Your first downloaded wallpaper is up and running. Enjoying WallpaperMachine? You can help it grow.'),
        `${choice('star', 'github', t('Star on GitHub'), t('Help others discover WallpaperMachine.'))}${choice('supporter', 'heart', t('Become a Supporter'), t('Support development with a one-time contribution.'))}`],
      star: [t('Like WallpaperMachine?'), t('A star on GitHub helps other Mac users find it.'),
        choice('star', 'github', t('Star on GitHub'), t('Opens the project on GitHub.'))],
      telemetry: [t('Send performance data?'), t('It helps find what makes wallpapers slow: how long they take to apply, their frame rate and energy use, and your Mac’s model, sent once a day. No names, files or account details.'),
        choice('enableTelemetry', 'activity', t('Send performance data'), t('You can turn it off in Settings › Storage.'), false)],
    }[prompt];
    const details = prompt === 'telemetry' ? `<button type="button" class="link" data-action="telemetryDetails"${off}>${icon('external', 15)}<span class="button-label">${e(t('What is sent'))}</span></button>` : '';
    return `<div class="dialog-head"><div class="dialog-heading"><h2 id="support-dialog-title" tabindex="-1">${e(copy[0])}</h2></div><button type="button" class="quiet icon-button" data-action="supportPromptChoice" data-choice="dismiss" aria-label="${e(t('Close'))}">${icon('close')}</button></div><div class="dialog-body"><p id="support-dialog-description">${e(copy[1])}</p><div class="dialog-choices">${copy[2]}</div>${error ? `<p class="notice error" role="alert">${e(error)}</p>` : ''}<div class="dialog-actions">${details}${error && !acknowledged ? `<button type="button" data-action="supportPromptRetry"${off}>${e(t('Try again'))}</button>` : ''}<button type="button" class="quiet" data-action="supportPromptChoice" data-choice="dismiss">${e(t('Not now'))}</button></div></div>`;
  }

  function render(next) {
    state = next ?? state;
    const prompt = kind ?? state?.pendingPrompt;
    if (!CHOICES[prompt] || closed.has(prompt)) return;
    // Steam authentication and onboarding keep priority, including a new request that
    // arrives while this dialog is open. Resume this same presentation when they finish.
    if (blocked()) {
      if (container.open) container.close();
      return;
    }
    if (!kind) previousFocus = document.activeElement;
    kind = prompt;
    morph(container, content(kind));
    if (!container.open) {
      container.showModal();
      container.querySelector('#support-dialog-title')?.focus();
    }
    if (!acknowledgementAttempted) acknowledge();
  }

  function acknowledge() {
    if (acknowledged) return Promise.resolve(true);
    if (acknowledgement) return acknowledgement;
    acknowledgementAttempted = true;
    error = '';
    const prompt = kind;
    // Deferring the call assigns the promise before send() synchronously re-renders.
    // A reply that arrives after its prompt closed belongs to nobody: the next prompt
    // acknowledges for itself.
    acknowledgement = Promise.resolve().then(() => send('supportPromptShown', { prompt })).then(() => {
      if (kind === prompt) acknowledged = true;
      return true;
    }).catch(failure => {
      if (kind === prompt) error = failure?.message || String(failure);
      return false;
    }).finally(() => {
      acknowledgement = null;
      render(state);
    });
    return acknowledgement;
  }

  // The next prompt, on a later day, starts from scratch.
  function close() {
    closed.add(kind);
    kind = null;
    acknowledged = false;
    acknowledgementAttempted = false;
    error = '';
    const wasOpen = container.open;
    if (wasOpen) container.close();
    if (wasOpen) restoreFocus(previousFocus);
  }

  async function choose(choice) {
    const prompt = kind;
    if (!prompt || !CHOICES[prompt].includes(choice)) return;
    // Leaving is always available, even when persistence or opening a link fails.
    if (choice === 'dismiss') {
      close();
      try { await send('supportPromptChoice', { prompt, choice }); } catch { /* The panel shows the connection error. */ }
      return;
    }
    if (choosing) return;
    choosing = true;
    error = '';
    render(state);
    try {
      if (!await acknowledge() || kind !== prompt) return;
      await send('supportPromptChoice', { prompt, choice });
      close();
    } catch (failure) {
      error = failure?.message || String(failure);
    } finally {
      choosing = false;
      render(state);
    }
  }

  async function details() {
    error = '';
    try { await send('telemetryDetails'); } catch (failure) { error = failure?.message || String(failure); }
    render(state);
  }

  container.addEventListener('click', event => {
    const control = event.target.closest('[data-action]');
    if (!control || control.disabled) return;
    if (control.dataset.action === 'supportPromptRetry') acknowledge();
    else if (control.dataset.action === 'supportPromptChoice') choose(control.dataset.choice);
    else if (control.dataset.action === 'telemetryDetails') details();
  });
  container.addEventListener('cancel', event => { event.preventDefault(); choose('dismiss'); });
  document.addEventListener('visibilitychange', () => render(state));
  return { render };
}
