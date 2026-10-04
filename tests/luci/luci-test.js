// luci-test.js - LuCI characterization for luci-app-ha-cluster (T25)
//
// Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Drives the LuCI pages of a running node with Playwright and writes one
// text file per observation to the output directory:
//
//   snapshot/<fixture>.out  UCI -> UI: every page and edit modal rendered
//                           for a fixture (old option names, migrated
//                           first when a migration script is given)
//   missing/<daemon>.out    pages rendered with a daemon binary removed
//   action/<name>.out       UI -> UCI: changes staged by a scripted edit
//                           (Save, never Apply), plus notifications and
//                           invalid fields
//   hint/<name>.out         sync sections of General and the Status page
//                           with an authoritative dnsmasq
//   layout/<page>.out       layout findings (overflow, overlap, alignment,
//                           contrast, unlabeled narrow cells) at 1280 and
//                           375 px, light and dark
//   computed/status.out     Status page compared with the rpcd status JSON
//   computed/console.out    console errors and page errors, all phases
//   screenshots/*.png       review material, not compared
//
// Run it from a shell that reaches the node addresses (rootless podman:
// "podman unshare --rootless-netns").
//
// Usage: node luci-test.js --node NAME --url URL --out DIR [--migration FILE]

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const args = {};
for (let i = 2; i < process.argv.length; i += 2)
	args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];

const NODE = args.node;
const BASE = args.url;
const OUT = args.out;
const MIGRATION = args.migration || '';
const PHASES = (args.phases || 'status,snapshot,missing,action,hint,layout').split(',');
const ONLY = args.only ? args.only.split(',') : null;
const RUNTIME = process.env.CONTAINER_RUNTIME || 'podman';
const FIXTURES = path.join(__dirname, 'fixtures');

if (!NODE || !BASE || !OUT) {
	console.error('Usage: node luci-test.js --node NAME --url URL --out DIR [--migration FILE]');
	process.exit(2);
}

const PAGES = ['status', 'simple', 'keepalived-advanced', 'owsync-advanced', 'lease-sync-advanced'];
const VIEWPORTS = [1280, 375];
const SCHEMES = ['light', 'dark'];
const DAEMONS = { 'lease-sync': '/usr/sbin/lease-sync', 'owsync': '/usr/bin/owsync' };

const consoleLog = [];

// ============================================
// Node helpers
// ============================================

function sh(cmd, input) {
	return execFileSync(RUNTIME, ['exec', '-i', NODE, 'sh', '-c', cmd],
		{ input: input || '', encoding: 'utf8' });
}

function applyFixture(name) {
	sh('cat > /etc/config/ha-cluster',
		fs.readFileSync(path.join(FIXTURES, name + '.uci'), 'utf8'));
	if (MIGRATION)
		sh('cat > /tmp/t25-migrate && sh /tmp/t25-migrate; rm -f /tmp/t25-migrate',
			fs.readFileSync(MIGRATION, 'utf8'));
}

// Anonymous section names depend on the file content
function write(rel, text) {
	text = text.replace(/\bcfg[0-9a-f]{6}\b/g, '<anon>');
	const file = path.join(OUT, rel);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text.endsWith('\n') || !text ? text : text + '\n');
}

// ============================================
// Browser helpers
// ============================================

async function newPage(browser, width, scheme, phase) {
	const ctx = await browser.newContext({
		viewport: { width: width || 1280, height: 800 },
		colorScheme: scheme || 'light'
	});
	const page = await ctx.newPage();
	page.setDefaultTimeout(5000);
	page.on('dialog', d => d.accept());

	await page.goto(BASE + '/cgi-bin/luci/', { waitUntil: 'networkidle' });
	await page.fill('input[name=luci_password]', '');
	await page.click('button.cbi-button-positive');
	await page.waitForLoadState('networkidle');

	// Errors before login come from the LuCI login page itself
	page.on('console', m => {
		if (m.type() === 'error')
			consoleLog.push(`${phase}: ${page.url().replace(/.*\/ha-cluster\//, '')}: console: ${m.text()}`);
	});
	page.on('pageerror', e => {
		consoleLog.push(`${phase}: ${page.url().replace(/.*\/ha-cluster\//, '')}: pageerror: ${e.message}`);
	});
	return page;
}

async function settle(page) {
	await page.waitForLoadState('networkidle');
	await page.waitForFunction(() =>
		!document.querySelector('#view > .spinning') &&
		!document.querySelector('.modal .spinning') &&
		!document.querySelector('.cbi-map .spinning'), null, { timeout: 10000 });
	await page.waitForTimeout(200);
}

async function openPage(page, view) {
	await page.goto(`${BASE}/cgi-bin/luci/admin/services/ha-cluster/${view}`,
		{ waitUntil: 'networkidle' });
	await page.waitForSelector('#view > *');
	await settle(page);
}

async function closeModal(page) {
	await page.evaluate(() => L.ui.hideModal());
	await page.waitForTimeout(300);
}

// ============================================
// UCI -> UI serialization
// ============================================

// Text rendering of a subtree: form rows as "section.option [widget] Label:
// value", table rows as cells joined by " | ", other visible text as is.
function serializeIn(page, selector) {
	return page.evaluate(sel => {
		const root = document.querySelector(sel);
		if (!root)
			return '(no ' + sel + ')';

		const visible = el => el.checkVisibility() && !el.closest('[data-tab-active="false"]');
		const norm = s => (s || '').replace(/\s+/g, ' ').trim();
		const lines = [];

		const widgetValue = field => {
			const parts = [];
			field.querySelectorAll('input, select, textarea, .cbi-dynlist .item, [data-value]').forEach(w => {
				if (!visible(w) && w.type !== 'checkbox')
					return;
				if (w.matches('.cbi-dynlist .item')) {
					parts.push('item=' + norm(w.textContent));
				} else if (w.hasAttribute('data-value') && !w.matches('input, select, li')) {
					parts.push('chip=' + w.getAttribute('data-value'));
				} else if (w.tagName === 'SELECT') {
					const opts = [...w.options].map(o => o.value).join(',');
					parts.push(`select=${w.value} {${opts}}`);
				} else if (w.type === 'checkbox') {
					parts.push(w.checked ? '[x]' : '[ ]');
				} else if (w.type === 'hidden' || w.closest('.cbi-dynlist')) {
					return;
				} else if (w.type === 'password') {
					parts.push('password=' + w.value + (w.placeholder ? ` (placeholder "${w.placeholder}")` : ''));
				} else {
					parts.push('value=' + w.value + (w.placeholder ? ` (placeholder "${w.placeholder}")` : ''));
				}
			});
			field.querySelectorAll('button').forEach(b => {
				if (visible(b) && norm(b.textContent) && !b.closest('[data-value]'))
					parts.push('button "' + norm(b.textContent) + '"');
			});
			const clone = field.cloneNode(true);
			clone.querySelectorAll('input, select, textarea, button, .cbi-value-description, [data-value], .cbi-dynlist').forEach(n => n.remove());
			const text = norm(clone.textContent);
			if (text)
				parts.push('text "' + text + '"');
			return parts.join(' ');
		};

		const walk = el => {
			if (el.nodeType === Node.TEXT_NODE) {
				const t = norm(el.textContent);
				if (t)
					lines.push(t);
				return;
			}
			if (el.nodeType !== Node.ELEMENT_NODE || !visible(el))
				return;
			if (el.matches('.cbi-page-actions, .cbi-tabmenu, script, style'))
				return;

			if (el.matches('.cbi-value')) {
				const sid = el.closest('[data-section-id]');
				const key = (sid ? sid.getAttribute('data-section-id') : '?') + '.' + (el.getAttribute('data-name') || '?');
				const title = el.querySelector('.cbi-value-title');
				// Untitled options render their widget without a field wrapper
				const field = el.querySelector('.cbi-value-field') || (title ? null : el);
				lines.push(`${key} [${el.getAttribute('data-widget') || '?'}] ${norm(title && title.textContent)}: ${field ? widgetValue(field) : ''}`);
				const descr = el.querySelector('.cbi-value-description');
				if (descr && visible(descr) && norm(descr.textContent))
					lines.push('  help: ' + norm(descr.textContent));
				const err = el.querySelector('.cbi-input-invalid, .cbi-value-error');
				if (err)
					lines.push('  invalid');
				return;
			}

			if (el.matches('tr')) {
				const cells = [...el.children].filter(visible).map(c => {
					const btns = [...c.querySelectorAll('button')].filter(visible).map(b => '[' + (norm(b.textContent) || b.title || '?') + ']');
					const clone = c.cloneNode(true);
					clone.querySelectorAll('button').forEach(n => n.remove());
					const img = c.querySelector('img') ? '<img> ' : '';
					return (img + norm(clone.textContent) + ' ' + btns.join('')).trim();
				});
				const label = el.id ? el.id.replace(/^cbi-ha-cluster-/, '') + ': ' : '';
				lines.push('| ' + label + cells.join(' | '));
				return;
			}

			if (el.matches('h2, h3, h4'))
				lines.push(el.tagName.toLowerCase() + ': ' + norm(el.textContent));
			else if (el.matches('.alert-message, .label, em, strong, a') && !el.closest('tr'))
				lines.push(`<${el.matches('.alert-message') ? 'alert' : el.matches('a') ? 'link' : el.matches('.label') ? 'label' : el.tagName.toLowerCase()}> ` + norm(el.textContent) +
					(el.matches('a') ? ' -> ' + el.getAttribute('href') : ''));
			else if (el.matches('input, select, textarea, button'))
				lines.push(`<${el.tagName.toLowerCase()}> ` + (el.value || norm(el.textContent) || el.placeholder || ''));
			else
				el.childNodes.forEach(walk);
		};
		walk(root);
		return lines.join('\n');
	}, selector);
}

// Status values that move on their own
function maskVolatile(text) {
	return text
		.replace(/^(\| [^|]*\| \S+ \| )\d+( \| )[^|\n]*$/gm, '$1<pid>$2<uptime>')
		.replace(/\b(Just now|Never|\d+ (minute|hour|day)s? ago)\b/g, '<time>');
}

async function snapshotModal(page) {
	await page.waitForSelector('.modal');
	await settle(page);
	const tabs = await page.$$('.modal .cbi-tabmenu li');
	let text = '';
	if (tabs.length) {
		for (let i = 0; i < tabs.length; i++) {
			await page.click(`.modal .cbi-tabmenu li >> nth=${i}`);
			await page.waitForTimeout(150);
			text += `[tab ${await tabs[i].innerText()}]\n` + await serializeIn(page, '.modal') + '\n';
		}
	} else {
		text = await serializeIn(page, '.modal') + '\n';
	}
	return text;
}

async function snapshotPage(page, view) {
	try {
		await openPage(page, view);
	} catch (e) {
		return `==== ${view}\n(page did not load)\n`;
	}
	let text = `==== ${view}\n` + await serializeIn(page, '#view') + '\n';
	if (view === 'status')
		return maskVolatile(text);

	const rows = await page.$$eval('#view .cbi-section-table-row',
		rs => rs.filter(r => r.querySelector('.cbi-button-edit')).map(r => r.id || r.getAttribute('data-sid')));
	for (const id of rows) {
		await page.click(`[id="${id}"] .cbi-button-edit`);
		text += `==== ${view} modal ${id.replace(/^cbi-ha-cluster-/, '')}\n` + await snapshotModal(page);
		await closeModal(page);
	}
	return text;
}

async function snapshotFixture(browser, fixture, pages) {
	applyFixture(fixture);
	const page = await newPage(browser, 1280, 'light', 'snapshot ' + fixture);
	let text = '';
	for (const view of pages || PAGES)
		text += await snapshotPage(page, view);
	await page.context().close();
	return text;
}

// ============================================
// UI -> UCI actions
// ============================================

async function stagedChanges(page) {
	return page.evaluate(async () => {
		const rpc = await L.require('rpc');
		const call = rpc.declare({ object: 'uci', method: 'changes', params: ['config'], expect: { changes: [] } });
		const changes = await call('ha-cluster');
		const names = {};
		let n = 0;
		const anon = s => /^cfg[0-9a-f]{6}$/.test(s) ? (names[s] = names[s] || '<anon' + (++n) + '>') : s;
		return changes.map(c => c.map((v, i) => i === 1 ? anon(v) : v))
			.map(c => c.join(' '))
			.join('\n');
	});
}

async function notifications(page) {
	return page.$$eval('#tabmenu ~ * .alert-message, #maincontent > .alert-message, .alert-message',
		els => els.filter(e => e.checkVisibility() && !/No password set/.test(e.textContent))
			.map(e => e.innerText.replace(/\s*Dismiss\s*$/, '').replace(/\s+/g, ' ').trim())
			.filter(t => t)
			.map(t => 'notification: ' + t));
}

async function invalidFields(page) {
	return page.$$eval('.cbi-input-invalid, .cbi-value-error',
		els => els.filter(e => e.checkVisibility())
			.map(e => 'invalid: ' + ((e.closest('.cbi-value') || {}).id || e.id || e.className)));
}

async function saveMain(page) {
	await page.click('.cbi-page-actions .cbi-button-save');
	await settle(page);
}

async function modalSave(page) {
	await page.click('.modal .cbi-button-positive');
	await settle(page);
}

function field(sid, name) {
	return `[data-section-id="${sid}"] .cbi-value[data-name="${name}"]`;
}

async function setCheckbox(page, sel, on) {
	await page.locator(sel + ' input[type=checkbox]').setChecked(on);
}

async function fill(page, sel, value) {
	await page.fill(sel + ' input:not([type=hidden])', value);
	await page.locator(sel + ' input:not([type=hidden])').blur();
}

async function select(page, sel, value) {
	await page.selectOption(sel + ' select', value);
}

async function dynlistAdd(page, sel, value) {
	const input = page.locator(sel + ' .cbi-dynlist input[type=text]').last();
	await input.fill(value);
	await input.press('Enter');
}

async function addNamed(page, section, name) {
	await page.locator(`#cbi-ha-cluster-${section} .cbi-section-create-name`).pressSequentially(name);
	await page.click(`#cbi-ha-cluster-${section} .cbi-section-create .cbi-button-add`);
	await page.waitForSelector('.modal');
	await settle(page);
}

// Each action: [name, fixture, page, steps]. Steps leave staged changes;
// the harness then reads them.
const ACTIONS = [
	['general-cluster', 'full', 'simple', async p => {
		await setCheckbox(p, field('config', 'enabled'), false);
		await fill(p, field('config', 'node_priority'), '120');
		await select(p, field('config', 'vrrp_transport'), 'multicast');
		await saveMain(p);
	}],
	['general-peer-add', 'full', 'simple', async p => {
		await p.click('#cbi-ha-cluster-peer .cbi-button-add');
		await p.waitForSelector('.modal');
		await fill(p, field('_new_', 'name'), 'router3');
		await fill(p, field('_new_', 'address'), '192.168.50.20');
		await select(p, field('_new_', 'source_address'), '192.168.50.10');
		await setCheckbox(p, field('_new_', 'vrrp_only'), true);
		await modalSave(p);
	}],
	['general-peer-family-mismatch', 'full', 'simple', async p => {
		await p.click('#cbi-ha-cluster-peer .cbi-button-add');
		await p.waitForSelector('.modal');
		await fill(p, field('_new_', 'name'), 'router3');
		await fill(p, field('_new_', 'address'), 'fd00:192:168:50::20');
		await select(p, field('_new_', 'source_address'), '192.168.50.10');
		await modalSave(p);
		await closeModal(p);
	}],
	['general-peer-edit-unchanged', 'full', 'simple', async p => {
		await p.click('[id="cbi-ha-cluster-peer3"] .cbi-button-edit');
		await p.waitForSelector('.modal');
		await settle(p);
		await modalSave(p);
		await saveMain(p);
	}],
	['general-peer-vrrp-only', 'full', 'simple', async p => {
		await p.click('[id="cbi-ha-cluster-peer1"] .cbi-button-edit');
		await p.waitForSelector('.modal');
		await setCheckbox(p, '.modal ' + field('peer1', 'vrrp_only'), true);
		await modalSave(p);
		await saveMain(p);
	}],
	['general-vip-add-first', 'bare', 'simple', async p => {
		await p.click('#cbi-ha-cluster-vip .cbi-button-add');
		await p.waitForSelector('.modal');
		await settle(p);
		const sid = await p.getAttribute('.modal [data-section-id]', 'data-section-id');
		await select(p, field(sid, 'interface'), 'lan');
		await fill(p, field(sid, 'address'), '192.168.50.254');
		await modalSave(p);
		await saveMain(p);
	}],
	['general-vip-remove-last', 'shipped', 'simple', async p => {
		await p.click('#cbi-ha-cluster-vip .cbi-section-table-row .cbi-button-remove');
		await settle(p);
	}],
	['general-key-generate', 'shipped', 'simple', async p => {
		await p.click(field('config', '_generate_key') + ' button');
		await p.waitForSelector('.modal pre');
		await closeModal(p);
		await saveMain(p);
	}],
	['general-sync-options', 'full', 'simple', async p => {
		await setCheckbox(p, field('config', 'lease_sync'), false);
		await setCheckbox(p, field('config', '_group_dhcp'), false);
		await setCheckbox(p, field('config', '_group_firewall'), false);
		await saveMain(p);
	}],
	['general-sync-options-on', 'sync-off', 'simple', async p => {
		await setCheckbox(p, field('config', 'lease_sync'), true);
		await setCheckbox(p, field('config', '_group_dhcp'), true);
		await setCheckbox(p, field('config', '_group_firewall'), true);
		await saveMain(p);
	}],
	['vrrp-instance-add', 'full', 'keepalived-advanced', async p => {
		await addNamed(p, 'vrrp_instance', 'guest');
		await fill(p, field('guest', 'vrid'), '20');
		await select(p, field('guest', 'interface'), 'lan');
		await modalSave(p);
		await saveMain(p);
	}],
	['vrrp-instance-vrid-duplicate', 'full', 'keepalived-advanced', async p => {
		await addNamed(p, 'vrrp_instance', 'guest');
		await fill(p, field('guest', 'vrid'), '51');
		await select(p, field('guest', 'interface'), 'lan');
		await modalSave(p);
		await closeModal(p);
	}],
	['vrrp-instance-edit', 'full', 'keepalived-advanced', async p => {
		await p.click('[id="cbi-ha-cluster-main"] .cbi-button-edit');
		await p.waitForSelector('.modal');
		await p.click('.modal .cbi-tabmenu li[data-tab="timing"]');
		await fill(p, field('main', 'advert_int'), '2');
		await setCheckbox(p, field('main', 'nopreempt'), false);
		await p.click('.modal .cbi-tabmenu li[data-tab="auth"]');
		await select(p, field('main', 'auth_type'), 'pass');
		await fill(p, field('main', 'auth_pass'), 'abcd1234');
		await modalSave(p);
		await saveMain(p);
	}],
	['vrrp-global', 'full', 'keepalived-advanced', async p => {
		const sid = await p.getAttribute('#view [data-section-id]', 'data-section-id');
		await fill(p, field(sid, 'max_auto_priority'), '10');
		await select(p, field(sid, 'log_level'), '1');
		await dynlistAdd(p, field(sid, 'notification_email'), 'ops@example.com');
		await fill(p, field(sid, 'smtp_server'), '192.168.50.3');
		await saveMain(p);
	}],
	['vrrp-script-add', 'full', 'keepalived-advanced', async p => {
		await addNamed(p, 'script', 'check_dns');
		await fill(p, field('check_dns', 'script'), '/usr/bin/nslookup openwrt.org 127.0.0.1');
		await fill(p, field('check_dns', 'weight'), '-20');
		await modalSave(p);
		await saveMain(p);
	}],
	['sync-group-add', 'full', 'owsync-advanced', async p => {
		await addNamed(p, 'sync_group', 'wireguard');
		await dynlistAdd(p, field('wireguard', 'config_files'), 'wireguard');
		await dynlistAdd(p, field('wireguard', 'config_files'), '/etc/wireguard');
		await modalSave(p);
		await saveMain(p);
	}],
	['sync-group-disable', 'full', 'owsync-advanced', async p => {
		await p.click('[id="cbi-ha-cluster-openvpn"] .cbi-button-edit');
		await p.waitForSelector('.modal');
		await setCheckbox(p, field('openvpn', 'enabled'), false);
		await modalSave(p);
		await saveMain(p);
	}],
	['sync-group-edit-absent-enabled', 'full', 'owsync-advanced', async p => {
		await p.click('[id="cbi-ha-cluster-ipsec"] .cbi-button-edit');
		await p.waitForSelector('.modal');
		await settle(p);
		await modalSave(p);
		await saveMain(p);
	}],
	['sync-exclusions', 'full', 'owsync-advanced', async p => {
		await p.click('[data-value="wireless"] button');
		await p.fill('#view .cbi-value[data-name="file"] input[type=text]', '/etc/dropbear/*.key');
		await p.click('#view .cbi-value[data-name="file"] .cbi-button-add');
		await saveMain(p);
	}],
	['sync-global', 'full', 'owsync-advanced', async p => {
		const sid = await p.getAttribute('#view [data-section-id]', 'data-section-id');
		await fill(p, field(sid, 'sync_interval'), '60');
		await select(p, field(sid, 'owsync_log_level'), '3');
		await saveMain(p);
	}],
	['lease-sync-tuning', 'full', 'lease-sync-advanced', async p => {
		const sid = await p.getAttribute('#view [data-section-id]', 'data-section-id');
		await fill(p, field(sid, 'lease_sync_port'), '5400');
		await select(p, field(sid, 'lease_sync_log_level'), '1');
		await saveMain(p);
	}]
];

async function runAction(browser, [name, fixture, view, steps]) {
	applyFixture(fixture);
	const page = await newPage(browser, 1280, 'light', 'action ' + name);
	let text;
	try {
		await openPage(page, view);
		await steps(page);
		text = [
			'staged:',
			(await stagedChanges(page)).replace(/'[0-9a-f]{64}'|\b[0-9a-f]{64}\b/g, '<key64>') || '(none)',
			...(await notifications(page)),
			...(await invalidFields(page))
		].join('\n');
	} catch (e) {
		const lines = e.message.replace(/\x1b\[[0-9;]*m/g, '').split('\n');
		const waiting = lines.find(l => /waiting for/.test(l));
		text = 'action failed: ' + lines[0] + (waiting ? ' ' + waiting.trim() : '');
	}
	await page.context().close();
	return text;
}

// ============================================
// DHCP authoritative hint
// ============================================

// Each case: [name, fixture, node commands run after the fixture], with
// an authoritative dnsmasq. The hint goes under the DHCP config sync when
// that applies, else under lease sync; never on Status.
const HINTS = [
	['dhcp-sync', 'full', ''],
	['lease-sync', 'full', 'uci set ha-cluster.dhcp.enabled=0 && uci commit ha-cluster']
];

async function hintCase(browser, [name, fixture, commands]) {
	applyFixture(fixture);
	if (commands)
		sh(commands);
	const page = await newPage(browser, 1280, 'light', 'hint ' + name);
	let text = '';
	for (const view of ['simple', 'status']) {
		text += `==== ${view}\n`;
		try {
			await openPage(page, view);
		} catch (e) {
			text += '(page did not load)\n';
			continue;
		}
		const lines = (await serializeIn(page, '#view')).split('\n');
		if (view === 'simple') {
			const start = lines.indexOf('h3: Configuration Files');
			text += (start < 0 ? '(no Configuration Files section)' : lines.slice(start).join('\n')) + '\n';
		} else {
			// Headings show the page rendered
			const hint = lines.filter(l => /authoritative/i.test(l));
			text += lines.filter(l => /^h[23]: /.test(l)).join('\n') + '\n' +
				(hint.length ? hint.join('\n') : '(no mention of authoritative)') + '\n';
		}
	}
	await page.context().close();
	return text;
}

// ============================================
// Layout checks
// ============================================

// Runs in the page. Returns [finding, detail] pairs; findings go to the
// compared output, details (with coordinates) to the log only.
function layoutChecks(rootSel) {
	const root = document.querySelector(rootSel);
	const vw = document.documentElement.clientWidth;
	const visible = el => el.checkVisibility() && el.getClientRects().length > 0 && !el.closest('[data-tab-active="false"]');
	const norm = s => (s || '').replace(/\s+/g, ' ').trim();
	const out = [];
	const TOL = 1;

	// A cell is named by its table and column header, not by its content
	const cellName = td => {
		const table = td.closest('table');
		const titles = table.querySelector('tr');
		const heads = titles ? [...titles.children] : [];
		let col = 0;
		for (const c of td.parentElement.children) {
			if (c === td)
				break;
			col += Number(c.getAttribute('colspan') || 1);
		}
		let x = 0;
		const head = heads.find(h => { const hit = x === col; x += Number(h.getAttribute('colspan') || 1); return hit; });
		const section = table.closest('.cbi-section, .cbi-section-node');
		const h3 = section && section.querySelector('h3');
		const tr = td.parentElement;
		return `table "${norm((h3 && !h3.closest('table') ? h3 : heads[0] || {}).textContent)}"` +
			(tr.id ? ' row ' + tr.id.replace(/^cbi-ha-cluster-/, '') : '') +
			` column "${norm(head && head.textContent)}"`;
	};

	const describe = el => {
		const cell = el.closest('td, th');
		if (cell && !el.closest('.cbi-value'))
			return cellName(cell) + (el === cell ? '' : ' ' + el.tagName.toLowerCase());
		const row = el.closest('.cbi-value');
		const sec = el.closest('[data-section-id]');
		const tr = el.closest('tr');
		let where = '';
		if (row)
			where = (sec ? sec.getAttribute('data-section-id') + '.' : '') + row.getAttribute('data-name');
		else if (tr && tr.id)
			where = tr.id.replace(/^cbi-ha-cluster-/, '');
		else {
			const section = el.closest('.cbi-section, .cbi-map, .modal');
			const h = section && section.querySelector('h2, h3, h4');
			where = h ? '"' + norm(h.textContent) + '"' : '?';
		}
		const cls = typeof el.className === 'string' && el.className.trim() ? '.' + el.className.trim().split(/\s+/)[0] : '';
		const text = norm(el.value || el.textContent).replace(/[0-9a-f]{16,}/g, '<hex>').slice(0, 30);
		return `${where} ${el.tagName.toLowerCase()}${cls}${text ? ' "' + text + '"' : ''}`;
	};
	const add = (kind, el, detail) => out.push([`${kind}: ${describe(el)}`, detail || '']);
	const rect = el => el.getBoundingClientRect();

	// Extent of the text itself for text elements (line boxes include leading)
	const ink = el => {
		if (el.matches('input, select, textarea, button, img'))
			return rect(el);
		const rs = [];
		el.childNodes.forEach(n => {
			if (n.nodeType === Node.TEXT_NODE && norm(n.textContent)) {
				const range = document.createRange();
				range.selectNodeContents(n);
				rs.push(...range.getClientRects());
			}
		});
		if (!rs.length)
			return rect(el);
		return {
			left: Math.min(...rs.map(r => r.left)), right: Math.max(...rs.map(r => r.right)),
			top: Math.min(...rs.map(r => r.top)), bottom: Math.max(...rs.map(r => r.bottom))
		};
	};

	const all = [...root.querySelectorAll('*')].filter(visible);
	const ownText = el => [...el.childNodes].some(n => n.nodeType === Node.TEXT_NODE && norm(n.textContent));
	const boxes = all.filter(el => el.matches('input:not([type=hidden]), select, textarea, button, img, label.cbi-value-title') || ownText(el));

	// Overflow: out of the viewport, out of the enclosing field or cell, clipped text
	boxes.forEach(el => {
		const r = rect(el);
		if (r.width === 0 || r.height === 0)
			return;
		if (r.right > vw + TOL || r.left < -TOL)
			add('outside viewport', el, `${r.left}..${r.right} vw=${vw}`);
		// Table cells are placed by the table (the theme offsets them in
		// narrow layout); their content is checked against them.
		const box = el.matches('td, th') ? null : el.parentElement.closest('.cbi-value-field, .td, .th, .cbi-section, .modal');
		if (box) {
			const b = rect(box);
			if (r.right > b.right + TOL || r.left < b.left - TOL)
				add('overflows container', el, `${r.left}..${r.right} in ${b.left}..${b.right}`);
		}
		const cs = getComputedStyle(el);
		if (!el.matches('input, select, textarea') && cs.overflowX !== 'visible' && el.scrollWidth > el.clientWidth + TOL)
			add('clipped text', el, `${el.scrollWidth} > ${el.clientWidth}`);
	});

	// Broken images; stored values shown altered (e.g. text-transform)
	all.filter(el => el.matches('img') && el.complete && el.naturalWidth === 0)
		.forEach(el => add('broken image', el, el.getAttribute('src')));
	all.filter(el => el.matches('[data-value]:not(input, select, li, option)')).forEach(el => {
		const shown = norm(el.innerText).replace(/\s*\u00d7$/, '');
		if (shown !== el.getAttribute('data-value'))
			add('value shown altered', el, `"${shown}" for "${el.getAttribute('data-value')}"`);
	});

	// Overlap between boxes that are not nested
	for (let i = 0; i < boxes.length; i++) {
		const a = ink(boxes[i]);
		for (let j = i + 1; j < boxes.length; j++) {
			if (boxes[i].contains(boxes[j]) || boxes[j].contains(boxes[i]))
				continue;
			const b = ink(boxes[j]);
			const w = Math.min(a.right, b.right) - Math.max(a.left, b.left);
			const h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
			// Joined borders (input + attached button) overlap by a few pixels
			if (w > 3 && h > 3)
				add('overlaps ' + describe(boxes[j]), boxes[i], `${w}x${h}`);
		}
	}

	// Form rows: labels end on one x, fields start on one x; stacked rows
	// (narrow layout) share their left edge; label first line centred on
	// the first control; help text starts with the control.
	const mode = xs => {
		const count = {};
		xs.forEach(x => { count[x] = (count[x] || 0) + 1; });
		return Number(Object.keys(count).sort((a, b) => count[b] - count[a] || a - b)[0]);
	};
	const rows = all.filter(el => el.matches('.cbi-value') && !el.closest('tr'))
		.map(el => ({ el, title: el.querySelector(':scope > .cbi-value-title'), field: el.querySelector(':scope > .cbi-value-field') }))
		.filter(r => r.title && r.field && visible(r.title) && visible(r.field) && norm(r.title.textContent));
	const side = rows.filter(r => rect(r.title).bottom > rect(r.field).top + TOL);
	const stacked = rows.filter(r => !side.includes(r));
	if (side.length) {
		const titleRight = mode(side.map(r => Math.round(rect(r.title).right)));
		const fieldLeft = mode(side.map(r => Math.round(rect(r.field).left)));
		side.forEach(r => {
			if (Math.abs(rect(r.title).right - titleRight) > TOL)
				add('label not aligned with the other labels', r.title, `${rect(r.title).right} vs ${titleRight}`);
			if (Math.abs(rect(r.field).left - fieldLeft) > TOL)
				add('field not aligned with the other fields', r.field, `${rect(r.field).left} vs ${fieldLeft}`);
		});
	}
	stacked.forEach(r => {
		if (Math.abs(rect(r.title).left - rect(r.field).left) > TOL)
			add('stacked label and field not left-aligned', r.title, `${rect(r.title).left} vs ${rect(r.field).left}`);
	});
	rows.forEach(r => {
		const control = [...r.field.querySelectorAll('input:not([type=hidden]), select, textarea, button, .cbi-checkbox label, .cbi-dynlist > .item, [data-value]')]
			.find(c => visible(c) && rect(c).width > 0);
		if (!control)
			return;
		if (side.includes(r)) {
			const text = [...r.title.childNodes].find(n => n.nodeType === Node.TEXT_NODE && norm(n.textContent));
			if (text) {
				const range = document.createRange();
				range.selectNodeContents(text);
				const line = range.getClientRects()[0];
				const c = rect(control);
				if (line && Math.abs((line.top + line.bottom) / 2 - (c.top + c.bottom) / 2) > 4)
					add('label not vertically centred on its control', r.title,
						`${(line.top + line.bottom) / 2} vs ${(c.top + c.bottom) / 2}`);
			}
		}
	});
	// The theme indents help text for its icon: compare the indent
	const helps = rows.map(r => {
		const descr = r.field.querySelector(':scope > .cbi-value-description');
		const widget = [...r.field.children].find(c => c !== descr && visible(c));
		return descr && widget && visible(descr) ? { descr, offset: Math.round(rect(descr).left - rect(widget).left) } : null;
	}).filter(Boolean);
	if (helps.length) {
		const offset = mode(helps.map(h => h.offset));
		helps.forEach(h => {
			if (Math.abs(h.offset - offset) > TOL)
				add('help text not aligned with its control', h.descr, `indent ${h.offset} vs ${offset}`);
		});
	}

	// Headings and section descriptions share one left edge
	const heads = all.filter(el => el.matches('h2, h3, .cbi-map-descr, .cbi-section-descr') && !el.closest('tr'));
	if (heads.length) {
		const left = mode(heads.map(h => Math.round(rect(h).left)));
		heads.forEach(h => {
			if (Math.abs(rect(h).left - left) > TOL)
				add('heading not aligned with the other headings', h, `${rect(h).left} vs ${left}`);
		});
	}

	// Tables: cells start with their column header; action cells end on
	// one x; narrow layout without headers must label its cells.
	all.filter(el => el.matches('table')).forEach(table => {
		const trs = [...table.querySelectorAll('tr')].filter(visible);
		const head = trs.find(tr => tr.querySelector('th'));
		const body = trs.filter(tr => tr !== head && !tr.matches('.placeholder') && tr.querySelectorAll('td').length > 1);
		const headCells = head ? [...head.children].filter(visible) : [];
		if (head && headCells.length) {
			const cols = [];
			let x = 0;
			[...head.children].forEach(th => {
				const span = Number(th.getAttribute('colspan') || 1);
				if (span === 1 && visible(th))
					cols[x] = th;
				x += span;
			});
			const stackedCells = body.some(tr => {
				const tds = [...tr.children].filter(visible);
				return tds.some(td => rect(td).top >= rect(tds[0]).bottom - TOL);
			});
			if (!stackedCells)
				body.forEach(tr => {
					let c = 0;
					[...tr.children].forEach(td => {
						const span = Number(td.getAttribute('colspan') || 1);
						if (span === 1 && cols[c] && visible(td) && Math.abs(rect(td).left - rect(cols[c]).left) > TOL)
							add('cell not aligned with its column header', td, `${rect(td).left} vs ${rect(cols[c]).left}`);
						c += span;
					});
				});
		}
		// form.GridSection tables are labelled by LuCI itself
		if ((!head || !visible(head) || headCells.length === 0) && !table.matches('.cbi-section-table')) {
			const hasHeader = table.querySelector('th');
			body.forEach(tr => {
				const tds = [...tr.children].filter(visible);
				const isStacked = tds.some(td => rect(td).top >= rect(tds[0]).bottom - TOL);
				if (hasHeader && isStacked)
					tds.forEach(td => {
						if (!td.getAttribute('data-title') && !td.matches('.cbi-section-actions') && norm(td.textContent))
							add('cell without label in narrow layout', td);
					});
			});
		}
		const actions = body.map(tr => tr.querySelector(':scope > .cbi-section-actions')).filter(a => a && visible(a));
		const inner = actions.map(a => a.querySelector('div') || a);
		if (inner.length > 1) {
			const right = mode(inner.map(a => Math.round(rect(a).right)));
			inner.forEach(a => {
				if (Math.abs(rect(a).right - right) > TOL)
					add('row actions not aligned with the other rows', a, `${rect(a).right} vs ${right}`);
			});
		}
	});

	// Controls laid out on one line share their vertical centre
	all.filter(el => el.matches('.cbi-section-create, .control-group, .cbi-dynlist > .add-item, .modal .right, td.cbi-section-actions > div')).forEach(line => {
		const controls = [...line.querySelectorAll('input:not([type=hidden]), select, button')].filter(c => visible(c) && rect(c).height > 0);
		if (controls.length < 2)
			return;
		const top = Math.min(...controls.map(c => rect(c).top));
		const sameLine = controls.filter(c => rect(c).top < top + rect(controls[0]).height / 2);
		const centre = c => (rect(c).top + rect(c).bottom) / 2;
		const ref = centre(sameLine[0]);
		sameLine.forEach(c => {
			if (Math.abs(centre(c) - ref) > 2)
				add('control not vertically aligned with its neighbours', c, `${centre(c)} vs ${ref}`);
		});
	});

	// Side-by-side tables start at the same height
	all.filter(el => getComputedStyle(el).display === 'flex' && getComputedStyle(el).flexDirection === 'row').forEach(flex => {
		const firsts = [...flex.children].map(c => c.querySelector('tr')).filter(tr => tr && visible(tr));
		if (firsts.length > 1) {
			const tops = firsts.map(tr => rect(tr).top);
			if (Math.max(...tops) - Math.min(...tops) > TOL && Math.max(...firsts.map(tr => rect(tr).left)) > Math.min(...firsts.map(tr => rect(tr).right)))
				add('side-by-side tables not top-aligned', flex, tops.join(','));
		}
	});

	// Text contrast (WCAG AA: 4.5, 3 for large text)
	const parse = c => {
		const m = c.match(/rgba?\(([^)]+)\)/);
		if (!m)
			return null;
		const v = m[1].split(/[ ,/]+/).filter(Boolean).map(Number);
		return { r: v[0], g: v[1], b: v[2], a: v.length > 3 ? v[3] : 1 };
	};
	const lum = c => {
		const f = x => { x /= 255; return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4); };
		return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
	};
	const inlineColour = e => /(^|;)\s*(color|background)/.test(e.getAttribute('style') || '');
	const background = el => {
		const layers = [];
		let own = false;
		for (let e = el; e; e = e.parentElement) {
			own = own || inlineColour(e);
			const c = parse(getComputedStyle(e).backgroundColor);
			if (c && c.a > 0) {
				layers.push(c);
				if (c.a >= 1)
					break;
			}
		}
		layers.own = own;
		let res = { r: 255, g: 255, b: 255 };
		for (let i = layers.length - 1; i >= 0; i--) {
			const l = layers[i];
			res = { r: l.r * l.a + res.r * (1 - l.a), g: l.g * l.a + res.g * (1 - l.a), b: l.b * l.a + res.b * (1 - l.a) };
		}
		res.own = layers.own;
		return res;
	};
	all.filter(el => (ownText(el) || el.matches('input[type=text], input[type=password], select, textarea')) && !el.disabled).forEach(el => {
		const cs = getComputedStyle(el);
		const fg = parse(cs.color);
		if (!fg || fg.a === 0)
			return;
		const bg = background(el);
		// Theme colours are out of reach of the app: judge its own only
		if (!bg.own)
			return;
		const f = { r: fg.r * fg.a + bg.r * (1 - fg.a), g: fg.g * fg.a + bg.g * (1 - fg.a), b: fg.b * fg.a + bg.b * (1 - fg.a) };
		const l1 = lum(f), l2 = lum(bg);
		const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
		const size = parseFloat(cs.fontSize);
		const large = size >= 24 || (size >= 18.66 && Number(cs.fontWeight) >= 700);
		if (ratio < (large ? 3 : 4.5))
			add('low contrast', el, ratio.toFixed(2));
	});

	return out;
}

async function layoutFor(page, rootSel, label, shots) {
	const found = await page.evaluate(layoutChecks, rootSel);
	// Fixed overlays break full-page shots: take the modal alone
	const file = path.join(OUT, 'screenshots', shots + '.png');
	if (rootSel === '.modal')
		await page.locator('.modal').screenshot({ path: file });
	else
		await page.screenshot({ path: file, fullPage: true });
	return found.map(([f, d]) => [`${label}: ${f}`, d]);
}

async function layoutPage(browser, view) {
	const findings = [];
	for (const scheme of SCHEMES) {
		for (const width of VIEWPORTS) {
			const label = `${width} ${scheme}`;
			const page = await newPage(browser, width, scheme, `layout ${label}`);
			await openPage(page, view);
			findings.push(...await layoutFor(page, '#view', label, `${view}-${width}-${scheme}`));

			const edits = await page.$$eval('#view .cbi-section-table-row .cbi-button-edit', bs => bs.length);
			const seen = {};
			for (let i = 0; i < edits; i++) {
				const section = await page.evaluate(n =>
					document.querySelectorAll('#view .cbi-section-table-row .cbi-button-edit')[n].closest('.cbi-section').id, i);
				if (seen[section])
					continue;
				seen[section] = true;
				await page.click(`#view .cbi-section-table-row .cbi-button-edit >> nth=${i}`);
				await page.waitForSelector('.modal');
				await settle(page);
				const name = section.replace(/^cbi-ha-cluster-/, '');
				const tabs = await page.$$('.modal .cbi-tabmenu li');
				for (let t = 0; t < Math.max(tabs.length, 1); t++) {
					let tab = '';
					if (tabs.length) {
						await page.click(`.modal .cbi-tabmenu li >> nth=${t}`);
						await page.waitForTimeout(150);
						tab = ' ' + await tabs[t].getAttribute('data-tab');
					}
					findings.push(...await layoutFor(page, '.modal', `${label} modal ${name}${tab}`,
						`${view}-modal-${name}${tab.replace(' ', '-')}-${width}-${scheme}`));
				}
				await closeModal(page);
			}

			if (view === 'simple') {
				await page.click(field('config', '_generate_key') + ' button');
				await page.waitForSelector('.modal pre');
				await settle(page);
				findings.push(...await layoutFor(page, '.modal', `${label} modal generated key`,
					`${view}-modal-key-${width}-${scheme}`));
				await closeModal(page);
			}
			await page.context().close();
		}
	}
	return findings;
}

// ============================================
// Status page vs rpcd
// ============================================

async function statusVsRpcd(browser) {
	const page = await newPage(browser, 1280, 'light', 'status-rpcd');
	const lines = [];
	for (let attempt = 1; attempt <= 3; attempt++) {
		await openPage(page, 'status');
		const rpcd = JSON.parse(sh('ubus call ha-cluster status'));
		const ui = await page.evaluate(() => {
			const norm = s => (s || '').replace(/\s+/g, ' ').trim();
			const tables = [...document.querySelectorAll('#ha_status_content table')];
			const rows = t => [...t.querySelectorAll('tr')].filter(tr => tr.querySelector('td')).map(tr => [...tr.children].map(td => norm(td.textContent)));
			const byTitle = title => tables.find(t => norm(t.querySelector('th').textContent) === title);
			const overview = rows(byTitle('Cluster Overview'));
			const services = byTitle('Service') ? rows(byTitle('Service')) : rows(tables.find(t => /Service/.test(t.textContent) && /PID/.test(t.textContent)));
			const peers = tables.find(t => /Peer Name/.test(t.textContent));
			return {
				state: overview.find(r => r[0] === 'Cluster State')[1],
				role: overview.find(r => r[0] === 'Node Role')[1],
				instances: overview.filter(r => /^Instance: /.test(r[0])).map(r => [r[0].replace('Instance: ', ''), r[1]]),
				services: services.map(r => ({ name: r[0], status: r[1], pid: r[2] })),
				peers: peers ? rows(peers).map(r => ({ name: r[0], address: r[1], state: r[2] })) : []
			};
		});

		const expect = [];
		const check = (what, got, want) => expect.push(got === want ? `ok: ${what}` : `MISMATCH: ${what}: page "${got}", rpcd "${want}"`);
		check('state', ui.state, rpcd.state || 'UNKNOWN');
		check('role', ui.role, rpcd.role || 'UNKNOWN');
		const inst = Object.keys(rpcd.instances || {});
		if (inst.length > 1)
			inst.forEach(n => check(`instance ${n}`, (ui.instances.find(i => i[0] === n) || [])[1], rpcd.instances[n]));
		ui.services.forEach(s => {
			const r = (rpcd.services || {})[s.name] || {};
			const want = r.running ? 'Running' : r.required ? 'Stopped' : 'Disabled';
			check(`service ${s.name} status`, s.status, want);
			check(`service ${s.name} pid`, s.pid, String(r.pid || '-'));
		});
		check('peer count', String(ui.peers.length), String((rpcd.peers || []).length));
		(rpcd.peers || []).forEach((p, i) => {
			const u = ui.peers[i] || {};
			check(`peer ${i} name`, u.name, p.name || '-');
			check(`peer ${i} address`, u.address, p.address || '-');
			check(`peer ${i} state`, u.state, p.online ? 'Online' : 'Offline');
		});
		lines.length = 0;
		lines.push(`services on page: ${ui.services.map(s => s.name).join(' ')}`, ...expect);
		if (!expect.some(l => l.startsWith('MISMATCH')))
			break;
	}
	await page.context().close();
	return lines.join('\n');
}

// ============================================
// Main
// ============================================

async function main() {
	fs.mkdirSync(path.join(OUT, 'screenshots'), { recursive: true });
	sh('cp /etc/config/ha-cluster /tmp/t25-ha-cluster.orig');

	const browser = await chromium.launch();
	const log = [];
	try {
		// Live cluster config first: the running daemons match it
		if (PHASES.includes('status'))
			write('computed/status.out', await statusVsRpcd(browser));

		if (PHASES.includes('snapshot'))
		for (const f of fs.readdirSync(FIXTURES).filter(f => f.endsWith('.uci')).sort()) {
			const name = f.replace(/\.uci$/, '');
			write(`snapshot/${name}.out`, await snapshotFixture(browser, name));
		}

		if (PHASES.includes('missing'))
		for (const [daemon, bin] of Object.entries(DAEMONS)) {
			sh(`mv ${bin} /tmp/t25-${daemon}`);
			try {
				write(`missing/${daemon}.out`, await snapshotFixture(browser, 'full',
					['status', 'simple', 'owsync-advanced', 'lease-sync-advanced']));
			} finally {
				sh(`mv /tmp/t25-${daemon} ${bin}`);
			}
		}

		if (PHASES.includes('action'))
		for (const action of ACTIONS.filter(a => !ONLY || ONLY.includes(a[0])))
			write(`action/${action[0]}.out`, await runAction(browser, action));

		if (PHASES.includes('hint')) {
			sh('cp /etc/config/dhcp /tmp/t25-dhcp.orig && ' +
				'uci set dhcp.@dnsmasq[0].authoritative=1 && uci commit dhcp');
			try {
				for (const hint of HINTS.filter(h => !ONLY || ONLY.includes(h[0])))
					write(`hint/${hint[0]}.out`, await hintCase(browser, hint));
			} finally {
				sh('mv /tmp/t25-dhcp.orig /etc/config/dhcp');
			}
		}

		applyFixture('full');
		if (PHASES.includes('layout'))
		for (const view of PAGES.filter(v => !ONLY || ONLY.includes(v))) {
			const found = await layoutPage(browser, view);
			write(`layout/${view}.out`, [...new Set(found.map(f => f[0]))].sort().join('\n'));
			log.push(...found.map(f => `${view}: ${f[0]} [${f[1]}]`));
		}
	} finally {
		await browser.close();
		sh('cp /tmp/t25-ha-cluster.orig /etc/config/ha-cluster && rm -f /tmp/t25-ha-cluster.orig');
		for (const [daemon, bin] of Object.entries(DAEMONS))
			sh(`[ -e /tmp/t25-${daemon} ] && mv /tmp/t25-${daemon} ${bin}; true`);
		sh('[ -e /tmp/t25-dhcp.orig ] && mv /tmp/t25-dhcp.orig /etc/config/dhcp; true');
		fs.writeFileSync(path.join(OUT, 'layout-details.log'), log.join('\n') + '\n');
		write('computed/console.out', consoleLog.join('\n'));
	}
}

main().catch(e => {
	console.error(e.stack || e.message);
	process.exit(1);
});
