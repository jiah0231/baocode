// SPDX-License-Identifier: AGPL-3.0-only
// BaoCode chrome adaptation; the pinned NoteBoard modules remain unchanged.
import {iconButton} from './vendor/noteboard/plugins/shared/view.mjs';

export const compactToolbarCss = `
  .np-toolbar{min-height:29px;padding:2px 6px;gap:3px}
  .np-toolbar .np-name{display:none}
  .np-toolbar button{height:24px;min-width:24px;padding:0 6px;gap:3px;font-size:12px;border-radius:4px}
  .np-toolbar button.np-icon{width:24px;padding:0}
  .np-toolbar button svg{width:14px;height:14px}
  .np-toolbar .np-field{height:24px;width:44px;font-size:12px;border-radius:4px}
  .np-toolbar .np-sep{height:14px;margin:0 2px}
  .np-toolbar .np-group{flex-shrink:0}
  .np-toolbar .bao-preview-actions{display:inline-flex;align-items:center;gap:2px;margin-left:auto;order:100;flex-shrink:0}
  .np-toolbar .bao-preview-actions [hidden]{display:none}
  @media(pointer:coarse){
    .np-toolbar button,.np-toolbar .np-field{height:32px;min-width:32px}
    .np-toolbar button.np-icon{width:32px}
  }
`;

export function compactPreviewToolbar(root, {canOpenExternal, onReload, onOpenExternal}) {
  const toolbar = root?.querySelector('.np-toolbar');
  if (!toolbar) return null;
  const style = document.createElement('style');
  style.dataset.baoCompactToolbar = '';
  style.textContent = compactToolbarCss;
  root.append(style);
  const actions = document.createElement('span');
  actions.className = 'bao-preview-actions';
  const reload = iconButton('refresh', '重新加载', () => {
    if (reload.disabled) return;
    reload.disabled = true;
    onReload();
  }, 'np-ghost');
  const external = iconButton('external', '用系统应用打开', () => {
    if (!external.hidden) onOpenExternal();
  }, 'np-ghost');
  external.hidden = !canOpenExternal;
  actions.append(reload, external);
  toolbar.append(actions);
  return {setOpenExternalVisible: visible => { external.hidden = !visible; }};
}
