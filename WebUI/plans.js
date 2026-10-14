// Saved playlists on Settings → Displays. A display's playlist can be saved under a name and
// applied to any enabled, independent display later; the saved copies live natively
// (`libraryOrganization.plans` in the snapshot: id, name, playlist) apart from any display.
// A display that took a saved playlist keeps `planID` until one of its settings is edited by
// hand, which detaches it; deleting a saved playlist leaves the displays' copies in place.
// The rotation's Wallpapers menu also offers the library's collections here.
import { t } from './i18n.js';

const modeLabels = { off: 'Off', rotate: 'Rotate wallpapers', dayNight: 'Day and night' };
const orderLabels = { sequential: 'In order', shuffle: 'Shuffle' };

const plansOf = (state) => (state?.libraryOrganization?.plans || []).filter(plan => plan && typeof plan.id === 'string');
const collectionsOf = (state) => (state?.libraryOrganization?.collections || []).filter(item => item && typeof item.id === 'string');
export const organizationAvailable = (state) => Boolean(state?.libraryOrganization);
const collectionName = (state, id) => collectionsOf(state).find(item => item.id === id)?.name;

// Minutes as the interval menu names them, shared with the display rows in settings.js.
export function intervalLabel(minutes) {
  if (minutes === 1) return t('Every minute');
  if (minutes === 60) return t('Every hour');
  if (minutes === 1440) return t('Every day');
  if (minutes % 1440 === 0) return t('Every {count} days', { count: minutes / 1440 });
  return minutes % 60 === 0 ? t('Every {count} hours', { count: minutes / 60 }) : t('Every {count} minutes', { count: minutes });
}

// The How often choice that is not a number of minutes: a rotation that waits for the unlock.
export const unlockLabel = () => t('Each time the Mac is unlocked');

// What a rotation draws from, as the Wallpapers menu names it.
export function sourceLabel(state, playlist, listedCount) {
  switch (playlist.source) {
    case 'favorites': return t('Favorites');
    case 'list': return t('This display’s list ({count})', { count: listedCount });
    case 'collection': { const name = collectionName(state, playlist.collectionID); return name ? t('Collection “{name}”', { name }) : t('A collection that no longer exists'); }
    default: return t('All wallpapers');
  }
}

// One line describing a saved playlist, for the list of them.
export function playlistSummary(state, playlist) {
  const wallpaperTitle = (id) => (state.wallpapers || []).find(item => item.id === id)?.title || (id ? t('a removed wallpaper') : t('left as it is'));
  const clock = (minute) => `${String(Math.floor((Number(minute) || 0) / 60)).padStart(2, '0')}:${String((Number(minute) || 0) % 60).padStart(2, '0')}`;
  if (playlist.mode === 'rotate') return t('{source}, {order}, {interval}', { source: sourceLabel(state, playlist, (playlist.wallpaperIDs || []).length), order: t(orderLabels[playlist.order] || orderLabels.sequential), interval: (playlist.trigger === 'unlock' ? unlockLabel() : intervalLabel(Number(playlist.interval) || 30)).toLocaleLowerCase() });
  if (playlist.mode === 'dayNight') return t('Day: {day} from {dayStart}; night: {night} from {nightStart}', { day: wallpaperTitle(playlist.dayWallpaperID), dayStart: clock(playlist.dayStart), night: wallpaperTitle(playlist.nightWallpaperID), nightStart: clock(playlist.nightStart) });
  return t('Off');
}

// The Wallpapers menu of a rotation: the library, favorites, the display's own list, and each
// collection. A collection option carries its id, and choosing one selects the collection and
// the collection source together.
export function sourceSelect(ctx, key, label, playlist, listedCount, data, off) {
  const { e, state, draft } = ctx;
  const current = draft(key, playlist.source === 'collection' && playlist.collectionID ? `collection:${playlist.collectionID}` : playlist.source);
  const option = (value, title) => `<option value="${e(value)}"${current === value ? ' selected' : ''}>${e(title)}</option>`;
  const collections = collectionsOf(state);
  const orphan = playlist.source === 'collection' && !collectionName(state, playlist.collectionID);
  return `<select data-key="${e(key)}" aria-label="${e(label)}" ${data}${off ? ' disabled' : ''}>`
    + option('all', t('All wallpapers')) + option('favorites', t('Favorites')) + option('list', t('This display’s list ({count})', { count: listedCount }))
    + (collections.length ? `<optgroup label="${e(t('Collections'))}">${collections.map(item => option(`collection:${item.id}`, item.name)).join('')}</optgroup>` : '')
    + (orphan ? option('collection', t('A collection that no longer exists')) : '')
    + `</select>`;
}
export const sourceNote = (ctx, playlist) => playlist.source === 'collection' && !collectionName(ctx.state, playlist.collectionID) ? t('The collection this rotation used was deleted, so it plays nothing until you choose another source.') : organizationAvailable(ctx.state) && !collectionsOf(ctx.state).length ? t('Collections you make in Installed appear here too.') : '';

// An inline name field with its own Save and Cancel; the form's action and args go to native
// with the typed name added.
function nameForm(ctx, key, action, args, submitLabel, placeholder) {
  const { e, draft, view } = ctx;
  return `<form class="settings-inline-form" data-form="name" data-action="${e(action)}" data-args="${e(JSON.stringify(args))}" data-editor-key="${e(key)}" data-key="${e(`editor-${key}`)}">`
    + `<label class="sr-only" for="settings-editor-${e(key)}">${e(placeholder)}</label>`
    + `<input id="settings-editor-${e(key)}" type="text" name="name" required maxlength="128" autocomplete="off" spellcheck="false" placeholder="${e(placeholder)}" value="${e(draft(`editor-${key}`, view.editor?.key === key ? view.editor.name : ''))}" data-key="${e(`editor-${key}`)}" data-editor="${e(key)}">`
    + `<button type="submit" class="settings-button settings-primary"${view.pending.has(key) ? ' disabled' : ''}>${e(submitLabel)}</button>${ctx.button(t('Cancel'), 'editCancel', {})}</form>`;
}
function confirmRow(ctx, key, question, action, args) {
  const { e, button, view } = ctx;
  return `<div class="settings-confirm" role="group" data-key="${e(`confirm-${key}`)}"><span class="settings-note">${e(question)}</span>${button(t('Delete'), action, args, view.pending.has(key), 'settings-destructive')}${button(t('Cancel'), 'disarm', {})}</div>`;
}

// Rows for one display's Playlist disclosure: the saved playlist in use or one to apply, and
// Save as… for the settings above.
export function planRows(ctx, display, playlist, off) {
  const { e, state, view, row, button } = ctx;
  if (!organizationAvailable(state)) return '';
  const plans = plansOf(state);
  const key = `plan-save-${display.id}`;
  const using = plans.find(plan => plan.id === playlist.planID);
  const choose = `<select data-key="${e(`display-${display.id}-plan`)}" aria-label="${e(t('Saved playlist for {display}', { display: display.title }))}" data-plan-display="${e(display.id)}"${off || !plans.length ? ' disabled' : ''}>`
    + `<option value=""${using ? '' : ' selected'}>${e(plans.length ? t('Choose a saved playlist…') : t('No saved playlists yet'))}</option>`
    + plans.map(plan => `<option value="${e(plan.id)}"${using?.id === plan.id ? ' selected' : ''}>${e(plan.name)}</option>`).join('') + '</select>';
  const editing = view.editor?.key === key;
  const control = editing ? nameForm(ctx, key, 'playlistPlanSave', { displayID: display.id }, t('Save'), t('Playlist name')) : `${choose}${button(t('Save as…'), 'editBegin', { key, name: '' }, off || playlist.mode === 'off')}`;
  const note = using
    ? t('Using “{name}”. Changing a setting above keeps this display’s copy and detaches it from the saved playlist.', { name: using.name })
    : playlist.mode === 'off' ? t('Turn the playlist on to save it, or apply a saved one.') : t('Applying a saved playlist copies its settings to this display. Save as… keeps the settings above under a name.');
  return row(`display-${display.id}-plan-row`, t('Saved playlist'), control, note);
}

// Every saved playlist with what it does, to rename or delete. Applying happens on a display.
export function plansGroup(ctx) {
  const { e, state, view, group, button, busy } = ctx;
  if (!organizationAvailable(state)) return '';
  const plans = plansOf(state);
  const inUse = (plan) => Object.values(state.playlists || {}).filter(playlist => playlist?.planID === plan.id).length;
  const rows = plans.map(plan => {
    const renameKey = `plan-rename-${plan.id}`, deleteKey = `plan-delete-${plan.id}`;
    const count = inUse(plan);
    const status = count ? t(count === 1 ? 'On 1 display' : 'On {count} displays', { count }) : '';
    if (view.editor?.key === renameKey) return `<div class="settings-rule settings-plan" data-key="${e(`plan-${plan.id}`)}">${nameForm(ctx, renameKey, 'playlistPlanRename', { planID: plan.id }, t('Save'), t('Playlist name'))}</div>`;
    if (view.armed === deleteKey) return `<div class="settings-rule settings-plan" data-key="${e(`plan-${plan.id}`)}">${confirmRow(ctx, deleteKey, count ? t('Delete “{name}”? Displays using it keep their current playlist.', { name: plan.name }) : t('Delete “{name}”?', { name: plan.name }), 'playlistPlanDelete', { planID: plan.id })}</div>`;
    return `<div class="settings-rule settings-plan" data-key="${e(`plan-${plan.id}`)}"><span class="settings-rule-name"><span class="settings-plan-name">${e(plan.name)}</span><span class="settings-note">${e(playlistSummary(state, plan.playlist || {}))}${status ? ` · ${e(status)}` : ''}</span></span>${button(t('Rename…'), 'editBegin', { key: renameKey, name: plan.name }, busy)}${button(t('Delete…'), 'arm', { key: deleteKey }, busy, 'settings-destructive')}</div>`;
  }).join('');
  return group('playlist-plans', t('Saved playlists'), rows || `<p class="settings-empty" data-key="plans-empty">${e(t('No saved playlists yet. Set up a display’s playlist above, then choose Save as….'))}</p>`);
}
