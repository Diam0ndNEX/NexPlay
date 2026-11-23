import UIKit
import SwiftUI
import WebKit

// 8.18.0 Cheat engine for RPG Maker MV/MZ (replaces the 7.x one in GameTools.swift). Ideas from RPGPlayer, JoiPlay,
// Empo and Cheat Engine; the code is NexPlay's own.
// - The page script (CheatsFeature.script) takes a command name and numbers only, so nothing typed in the app can
//   run as script. Names (catalog) are read once; values (state) after every change.
// - Tabs: Quick (money, god mode, infinite HP/MP/TP, no skill cost, one-hit kills, always critical/escape/drop,
//   EXP and gold multipliers, walk through walls, always dash, no encounters, speed, save/menu unlock), Battle
//   (win, weaken, escape, each enemy), Party (level, EXP, HP/MP/TP, the 8 stats, max stats, skills, states,
//   who is in the party), Items (all kinds, give every item, lock a count), Map (teleport to any map, reset self
//   switches), Switches, Variables, Scan (find a variable by its value like Cheat Engine: equal, bigger, smaller,
//   changed, same), Pinned (favourites and locks; a lock keeps a value, 4 times a second).
// - English names (Apple's on-device translation, MachineTranslation.swift), kept per game.

final class CheatsFeature: PlayerFeature {
    /// Set by PlayerFeatures.make: machine translations of this game.
    weak var translation: TranslationFeature?

    static let script = #"""
    (function () {
        if (window.__nexCheat && window.__nexCheat.version >= 2) return;
        // 8.18.0 cheat engine, RPG Maker MV and MZ. Every call takes a name and numbers only, so nothing typed in the
        // app can run as script. Values are read from the saved fields (_hp, _items, _data...), never through plugin
        // code that could throw outside its scene.
        var X = window.__nexCheatState = window.__nexCheatState || {
            god: false, oneHit: false, through: false, noEncounters: false, infinite: false, noCost: false,
            escape: false, crit: false, drop: false, dash: false,
            exp: 1, gold: 1, locks: {}, scan: null, scanPrev: null
        };
        function ready() { return typeof $gameParty !== 'undefined' && $gameParty && typeof $gamePlayer !== 'undefined' && $gamePlayer; }
        function table(kind) { return kind === 1 ? $dataWeapons : kind === 2 ? $dataArmors : $dataItems; }
        function bag(kind) { return kind === 1 ? $gameParty._weapons : kind === 2 ? $gameParty._armors : $gameParty._items; }
        function n(x) { x = Number(x); return isFinite(x) ? x : 0; }
        function str(x) { return x === undefined || x === null ? '' : String(x); }
        function inBattle() { try { return !!($gameParty.inBattle && $gameParty.inBattle()); } catch (e) { return false; } }
        function actor(id) { try { return $gameActors.actor(id); } catch (e) { return null; } }
        function enemies() { try { return ($gameTroop && $gameTroop.members) ? $gameTroop.members() : []; } catch (e) { return []; } }
        function refresh() { try { if ($gameMap && $gameMap.requestRefresh) $gameMap.requestRefresh(); } catch (e) {} }
        function kill(enemy) {
            if (!enemy || (enemy.isDead && enemy.isDead())) return;
            enemy.setHp(0);
            try { if (enemy.isDead && !enemy.isDead() && enemy.die) enemy.die(); } catch (e) {}
            try { if (enemy.performCollapse) enemy.performCollapse(); } catch (e) {}
            try { if (enemy.refresh) enemy.refresh(); } catch (e) {}
        }
        function varValue(id) {
            var d = $gameVariables && $gameVariables._data;
            return d ? d[id] : undefined;
        }

        // MARK: commands
        var run = function (name, a, b, c, d) {
            try {
                if (!ready()) return 'Start or load a game first.';
                a = n(a); b = n(b); c = n(c); d = n(d);
                var who, thing;
                switch (name) {
                // money and items
                case 'gold': $gameParty.gainGold(a); break;
                case 'setgold': $gameParty.gainGold(Math.max(0, a) - n($gameParty._gold)); break;
                case 'item': case 'weapon': case 'armor':
                    var list = name === 'item' ? $dataItems : name === 'weapon' ? $dataWeapons : $dataArmors;
                    thing = list && list[a];
                    if (!thing) return 'No ' + name + ' with id ' + a + '.';
                    $gameParty.gainItem(thing, b || 1);
                    break;
                case 'setitem':
                    thing = table(a) && table(a)[b];
                    if (!thing) return 'No such item.';
                    var have = n((bag(a) || {})[b]);
                    $gameParty.gainItem(thing, Math.max(0, c) - have, false);
                    break;
                case 'allitems':
                    // a = kind (0 items, 1 weapons, 2 armors), b = how many, c = 1 also key items
                    var all = table(a) || [], count = Math.max(1, b || 99), added = 0;
                    for (var i = 1; i < all.length; i++) {
                        var e = all[i];
                        if (!e || !e.name) continue;
                        if (a === 0 && e.itypeId === 2 && !c) continue;
                        var now = n((bag(a) || {})[i]);
                        if (now < count) { $gameParty.gainItem(e, count - now, false); added++; }
                    }
                    return 'ok:' + added;
                case 'clearitems':
                    var tab = table(a) || [];
                    for (var j = 1; j < tab.length; j++) {
                        if (tab[j] && n((bag(a) || {})[j]) > 0 && !(a === 0 && tab[j].itypeId === 2)) $gameParty.loseItem(tab[j], n(bag(a)[j]), false);
                    }
                    break;
                // party
                case 'heal':
                    $gameParty.members().forEach(function (m) { m.recoverAll(); });
                    break;
                case 'recover': who = actor(a); if (who) who.recoverAll(); break;
                case 'level':
                    who = actor(a);
                    if (!who) return 'No actor with id ' + a + '.';
                    who.changeLevel(Math.max(1, Math.min(b, who.maxLevel())), false);
                    who.recoverAll();
                    break;
                case 'exp':
                    who = actor(a);
                    if (!who) return 'No actor with id ' + a + '.';
                    who.changeExp(Math.max(0, Math.round(b)), false);
                    break;
                case 'hp': who = actor(a); if (who) who.setHp(Math.max(0, Math.round(b))); break;
                case 'mp': who = actor(a); if (who) who.setMp(Math.max(0, Math.round(b))); break;
                case 'tp': who = actor(a); if (who) who.setTp(Math.max(0, Math.round(b))); break;
                case 'param':
                    // a actor, b param 0-7 (mhp mmp atk def mat mdf agi luk), c the value wanted
                    who = actor(a);
                    if (!who || b < 0 || b > 7) return 'No such actor or stat.';
                    who.addParam(b, Math.round(c) - who.param(b));
                    if (b === 0) who.setHp(Math.min(who.hp, who.mhp));
                    break;
                case 'maxparams':
                    who = actor(a);
                    if (!who) return 'No actor with id ' + a + '.';
                    for (var p = 0; p < 8; p++) {
                        var top = p < 2 ? 9999 : 999;
                        try { top = who.paramMax(p); } catch (e) {}
                        who.addParam(p, top - who.param(p));
                    }
                    who.recoverAll();
                    break;
                case 'resetparams':
                    who = actor(a);
                    if (who) { who._paramPlus = [0, 0, 0, 0, 0, 0, 0, 0]; who.refresh(); }
                    break;
                case 'learn': who = actor(a); if (who && $dataSkills[b]) who.learnSkill(b); break;
                case 'forget': who = actor(a); if (who) who.forgetSkill(b); break;
                case 'learnclass':
                    who = actor(a);
                    if (!who) return 'No actor with id ' + a + '.';
                    var cls = $dataClasses[who._classId];
                    (cls && cls.learnings || []).forEach(function (l) { if ($dataSkills[l.skillId]) who.learnSkill(l.skillId); });
                    break;
                case 'learnall':
                    who = actor(a);
                    if (!who) return 'No actor with id ' + a + '.';
                    for (var s = 1; s < $dataSkills.length; s++) {
                        var sk = $dataSkills[s];
                        if (sk && sk.name && sk.stypeId > 0) who.learnSkill(s);
                    }
                    break;
                case 'state':
                    who = actor(a);
                    if (!who || !$dataStates[b]) return 'No such actor or state.';
                    if (c) who.addState(b); else who.removeState(b);
                    break;
                case 'clearstates':
                    who = actor(a);
                    if (who) { who.clearStates(); who.refresh(); }
                    break;
                case 'addactor': if ($dataActors[a]) $gameParty.addActor(a); break;
                case 'removeactor':
                    if ($gameParty._actors.length <= 1) return 'The party needs at least one member.';
                    $gameParty.removeActor(a);
                    break;
                // toggles
                case 'god': X.god = !!a; break;
                case 'onehit': X.oneHit = !!a; break;
                case 'infinite': X.infinite = !!a; break;
                case 'nocost': X.noCost = !!a; break;
                case 'escape': X.escape = !!a; break;
                case 'crit': X.crit = !!a; break;
                case 'drop': X.drop = !!a; break;
                case 'dash': X.dash = !!a; break;
                case 'through': X.through = !!a; try { $gamePlayer.setThrough(!!a); } catch (e) {} break;
                case 'encounters': X.noEncounters = !!a; break;
                case 'expmul': X.exp = Math.max(0, Math.min(100, a || 1)); break;
                case 'goldmul': X.gold = Math.max(0, Math.min(100, a || 1)); break;
                case 'speed': $gamePlayer.setMoveSpeed(Math.max(1, Math.min(6, a))); break;
                case 'enablesave': $gameSystem.enableSave(); break;
                case 'enablemenu': $gameSystem.enableMenu(); break;
                // battle
                case 'win':
                    if (!inBattle()) return 'Not in a battle.';
                    enemies().forEach(kill);
                    break;
                case 'killenemy':
                    if (!inBattle()) return 'Not in a battle.';
                    kill(enemies()[a]);
                    break;
                case 'enemyhp':
                    if (!inBattle()) return 'Not in a battle.';
                    var foe = enemies()[a];
                    if (foe) foe.setHp(Math.max(0, Math.round(b)));
                    break;
                case 'weaken':
                    if (!inBattle()) return 'Not in a battle.';
                    enemies().forEach(function (en) { if (!en.isDead()) en.setHp(1); });
                    break;
                case 'abort':
                    if (!inBattle()) return 'Not in a battle.';
                    if (typeof BattleManager !== 'undefined') {
                        if (BattleManager.processAbort) BattleManager.processAbort(); else BattleManager.abort();
                    }
                    break;
                // map
                case 'teleport':
                    if (inBattle()) return 'Finish the battle first.';
                    if (typeof $dataMapInfos !== 'undefined' && $dataMapInfos && !$dataMapInfos[a]) return 'No map with id ' + a + '.';
                    $gamePlayer.reserveTransfer(a, Math.max(0, Math.round(b)), Math.max(0, Math.round(c)), $gamePlayer.direction(), 0);
                    break;
                case 'switch': $gameSwitches.setValue(a, !!b); refresh(); break;
                case 'variable': $gameVariables.setValue(a, b); refresh(); break;
                case 'selfswitches':
                    // turn every self switch of the current map off (re-run event pages)
                    var ss = $gameSelfSwitches && $gameSelfSwitches._data;
                    if (ss) Object.keys(ss).forEach(function (k) { if (String(k).split(',')[0] === String($gameMap.mapId())) delete ss[k]; });
                    if ($gameSelfSwitches.onChange) $gameSelfSwitches.onChange();
                    break;
                // locks: a type (1 variable, 2 switch, 3 gold, 4 item, 5 weapon, 6 armor), b id, c value, d 1 on 0 off
                case 'lock':
                    var key = a + ':' + b;
                    if (d) X.locks[key] = { type: a, id: b, value: c }; else delete X.locks[key];
                    applyLocks();
                    break;
                case 'unlockall': X.locks = {}; break;
                // value scan over variables: a mode (1 new =, 2 next =, 3 bigger, 4 smaller, 5 changed, 6 same, 7 reset)
                case 'scan': return scan(a, b);
                case 'save': if (typeof Scene_Save !== 'undefined') SceneManager.push(Scene_Save); break;
                case 'menu': if (typeof Scene_Menu !== 'undefined') SceneManager.push(Scene_Menu); break;
                default: return 'Unknown cheat.';
                }
                return 'ok';
            } catch (e) { return String((e && e.message) || e); }
        };
        run.version = 2;
        window.__nexCheat = run;

        function scan(mode, value) {
            var data = ($gameVariables && $gameVariables._data) || [];
            var size = Math.max(data.length, (($dataSystem && $dataSystem.variables) || []).length);
            var now = {};
            for (var i = 1; i < size && i < 20000; i++) { var v = data[i]; now[i] = typeof v === 'number' ? v : (v === undefined || v === null ? 0 : NaN); }
            if (mode === 7) { X.scan = null; X.scanPrev = null; return 'ok:0'; }
            var ids = [];
            if (mode === 1 || !X.scan) {
                for (var k in now) if (now[k] === value) ids.push(Number(k));
            } else {
                X.scan.forEach(function (id) {
                    var was = X.scanPrev ? X.scanPrev[id] : undefined, cur = now[id];
                    var keepIt = mode === 2 ? cur === value : mode === 3 ? cur > was : mode === 4 ? cur < was
                        : mode === 5 ? cur !== was : mode === 6 ? cur === was : false;
                    if (keepIt) ids.push(id);
                });
            }
            X.scan = ids;
            X.scanPrev = now;
            return 'ok:' + ids.length;
        }

        function applyLocks() {
            if (!ready()) return;
            for (var key in X.locks) {
                var l = X.locks[key];
                try {
                    if (l.type === 1) { if (varValue(l.id) !== l.value) $gameVariables.setValue(l.id, l.value); }
                    else if (l.type === 2) { if (!!$gameSwitches.value(l.id) !== !!l.value) $gameSwitches.setValue(l.id, !!l.value); }
                    else if (l.type === 3) { if (n($gameParty._gold) !== l.value) $gameParty.gainGold(l.value - n($gameParty._gold)); }
                    else if (l.type >= 4 && l.type <= 6) {
                        var kind = l.type - 4, item = table(kind) && table(kind)[l.id];
                        if (item) { var have = n((bag(kind) || {})[l.id]); if (have !== l.value) $gameParty.gainItem(item, l.value - have, false); }
                    }
                } catch (e) {}
            }
            if (X.infinite) {
                try {
                    $gameParty.members().forEach(function (m) {
                        if (m.isDead && m.isDead()) return;
                        if (m._hp !== m.mhp) m.setHp(m.mhp);
                        if (m._mp !== m.mmp) m.setMp(m.mmp);
                        if (m.maxTp && m._tp !== m.maxTp()) m.setTp(m.maxTp());
                    });
                } catch (e) {}
            }
        }
        if (!X.timer) X.timer = setInterval(applyLocks, 250);

        // MARK: snapshot (values only; names come from the catalog)
        window.__nexCheatSnapshot = function () {
            if (!ready()) return '';
            var out = {
                gold: n($gameParty._gold), speed: n($gamePlayer._moveSpeed) || 4,
                flags: { god: X.god, oneHit: X.oneHit, through: X.through, noEncounters: X.noEncounters, infinite: X.infinite,
                    noCost: X.noCost, escape: X.escape, crit: X.crit, drop: X.drop, dash: X.dash },
                exp: X.exp, goldRate: X.gold,
                party: [], counts: {}, switches: [], variables: {}, locks: [], battle: null, map: null, scan: null,
                canSave: true, canMenu: true
            };
            try { out.canSave = !!$gameSystem.isSaveEnabled(); out.canMenu = !!$gameSystem.isMenuEnabled(); } catch (e) {}
            ($gameParty._actors || []).forEach(function (actorId) {
                try {
                    var m = $gameActors.actor(actorId);
                    if (!m) return;
                    var data = $dataActors && $dataActors[actorId];
                    var cls = $dataClasses && $dataClasses[m._classId];
                    var params = [];
                    for (var p = 0; p < 8; p++) { try { params.push(Math.round(n(m.param(p)))); } catch (e) { params.push(0); } }
                    var states = [];
                    try { (m._states || []).forEach(function (sid) { var st = $dataStates[sid]; if (st && st.name) states.push(str(st.name)); }); } catch (e) {}
                    out.party.push({ id: actorId, name: str(m._name || (data && data.name)), level: Math.round(n(m._level)),
                        maxLevel: Math.round(Math.min(n(data && data.maxLevel) || 99, 9999)),
                        hp: n(m._hp), mhp: n(m.mhp), mp: n(m._mp), mmp: n(m.mmp), tp: n(m._tp),
                        exp: Math.round(n(m.currentExp ? m.currentExp() : 0)),
                        job: cls ? str(cls.name) : '', params: params, states: states,
                        skills: (m._skills || []).slice(0, 400).map(Number) });
                } catch (e) {}
            });
            [0, 1, 2].forEach(function (kind) {
                var b = bag(kind) || {};
                for (var id in b) { var c = n(b[id]); if (c) out.counts[kind + '-' + id] = Math.round(c); }
            });
            try {
                var swData = ($gameSwitches && $gameSwitches._data) || [];
                for (var s = 1; s < swData.length && s < 20000; s++) if (swData[s]) out.switches.push(s);
            } catch (e) {}
            try {
                var varData = ($gameVariables && $gameVariables._data) || [];
                for (var v = 1; v < varData.length && v < 20000; v++) {
                    var value = varData[v];
                    if (value === undefined || value === null || value === 0 || value === '') continue;
                    var text = '';
                    try { text = typeof value === 'object' ? JSON.stringify(value) : String(value); } catch (e) { text = '?'; }
                    out.variables[v] = { n: typeof value === 'number' && isFinite(value) ? value : 0, t: String(text).slice(0, 80) };
                }
            } catch (e) {}
            for (var key in X.locks) out.locks.push(X.locks[key]);
            if (inBattle()) {
                out.battle = { enemies: [] };
                enemies().forEach(function (en, index) {
                    try {
                        out.battle.enemies.push({ index: index, name: str(en.originalName ? en.originalName() : (en.enemy && en.enemy().name)),
                            letter: str(en._letter), hp: n(en._hp), mhp: n(en.mhp), dead: !!(en.isDead && en.isDead()) });
                    } catch (e) {}
                });
            }
            try {
                var mid = $gameMap.mapId();
                var info = typeof $dataMapInfos !== 'undefined' && $dataMapInfos ? $dataMapInfos[mid] : null;
                out.map = { id: mid, name: str(($gameMap.displayName && $gameMap.displayName()) || (info && info.name)),
                    x: n($gamePlayer.x), y: n($gamePlayer.y), width: n($gameMap.width && $gameMap.width()), height: n($gameMap.height && $gameMap.height()) };
            } catch (e) {}
            if (X.scan) {
                out.scan = { count: X.scan.length, ids: X.scan.slice(0, 300) };
            }
            return JSON.stringify(out);
        };

        // MARK: catalog (names, read once)
        window.__nexCheatCatalog = function () {
            if (typeof $dataSystem === 'undefined' || !$dataSystem) return '';
            var out = { items: [], actors: [], skills: [], states: [], maps: [], switches: [], variables: [], params: [], currency: '' };
            [0, 1, 2].forEach(function (kind) {
                try {
                    var list = table(kind) || [];
                    for (var i = 1; i < list.length && i < 6000; i++) {
                        var d = list[i];
                        if (!d || !d.name) continue;
                        out.items.push({ kind: kind, id: i, name: str(d.name), note: str(d.description).slice(0, 160),
                            key: kind === 0 && d.itypeId === 2, price: n(d.price) });
                    }
                } catch (e) {}
            });
            try { for (var a = 1; a < $dataActors.length; a++) if ($dataActors[a] && $dataActors[a].name) out.actors.push({ id: a, name: str($dataActors[a].name) }); } catch (e) {}
            try { for (var s = 1; s < $dataSkills.length && s < 6000; s++) if ($dataSkills[s] && $dataSkills[s].name) out.skills.push({ id: s, name: str($dataSkills[s].name), type: n($dataSkills[s].stypeId) }); } catch (e) {}
            try { for (var t = 1; t < $dataStates.length; t++) if ($dataStates[t] && $dataStates[t].name) out.states.push({ id: t, name: str($dataStates[t].name) }); } catch (e) {}
            try {
                if (typeof $dataMapInfos !== 'undefined' && $dataMapInfos) {
                    for (var m = 1; m < $dataMapInfos.length; m++) if ($dataMapInfos[m]) out.maps.push({ id: m, name: str($dataMapInfos[m].name) });
                }
            } catch (e) {}
            try { var sw = $dataSystem.switches || []; for (var w = 1; w < sw.length && w < 20000; w++) out.switches.push(str(sw[w])); } catch (e) {}
            try { var vr = $dataSystem.variables || []; for (var r = 1; r < vr.length && r < 20000; r++) out.variables.push(str(vr[r])); } catch (e) {}
            try { out.params = ($dataSystem.terms && $dataSystem.terms.params || []).slice(0, 8).map(str); } catch (e) {}
            try { out.currency = str($dataSystem.currencyUnit); } catch (e) {}
            return JSON.stringify(out);
        };

        // MARK: hooks
        (function hook(tries) {
            if (typeof Game_Player === 'undefined' || typeof Game_Battler === 'undefined' || typeof Game_Action === 'undefined') {
                if ((tries || 0) < 600) setTimeout(function () { hook((tries || 0) + 1); }, 100);
                return;
            }
            if (Game_Player.prototype.__nexHooked2) return;
            Game_Player.prototype.__nexHooked2 = true;
            var canEncounter = Game_Player.prototype.canEncounter;
            Game_Player.prototype.canEncounter = function () {
                return X.noEncounters ? false : canEncounter.apply(this, arguments);
            };
            var isThrough = Game_Player.prototype.isThrough;
            Game_Player.prototype.isThrough = function () {
                return X.through ? true : isThrough.apply(this, arguments);
            };
            if (Game_Player.prototype.isDashButtonPressed) {
                var dashButton = Game_Player.prototype.isDashButtonPressed;
                Game_Player.prototype.isDashButtonPressed = function () {
                    return X.dash ? true : dashButton.apply(this, arguments);
                };
            }
            var gainHp = Game_Battler.prototype.gainHp;
            Game_Battler.prototype.gainHp = function (value) {
                if ((X.god || X.infinite) && this.isActor && this.isActor() && value < 0) value = 0;
                if (X.oneHit && this.isEnemy && this.isEnemy() && value < 0) value = -Math.max(n(this.hp !== undefined ? this.hp : this._hp), -value);
                return gainHp.call(this, value);
            };
            // Damage goes through Game_Action.executeHpDamage -> gainHp in MV and MZ; some plugins call setHp.
            if (typeof Game_BattlerBase !== 'undefined') {
                var paySkillCost = Game_BattlerBase.prototype.paySkillCost;
                Game_BattlerBase.prototype.paySkillCost = function () {
                    if ((X.noCost || X.infinite) && this.isActor && this.isActor()) return;
                    return paySkillCost.apply(this, arguments);
                };
                var canPaySkillCost = Game_BattlerBase.prototype.canPaySkillCost;
                Game_BattlerBase.prototype.canPaySkillCost = function () {
                    if ((X.noCost || X.infinite) && this.isActor && this.isActor()) return true;
                    return canPaySkillCost.apply(this, arguments);
                };
            }
            if (Game_Action.prototype.itemCri) {
                var itemCri = Game_Action.prototype.itemCri;
                Game_Action.prototype.itemCri = function () {
                    if (X.crit && this.subject && this.subject() && this.subject().isActor && this.subject().isActor() && this.isDamage && this.isDamage()) return 1;
                    return itemCri.apply(this, arguments);
                };
            }
            if (typeof Game_Enemy !== 'undefined' && Game_Enemy.prototype.dropItemRate) {
                var dropRate = Game_Enemy.prototype.dropItemRate;
                Game_Enemy.prototype.dropItemRate = function () {
                    return X.drop ? 1e9 : dropRate.apply(this, arguments);
                };
            }
            if (typeof Game_Actor !== 'undefined' && Game_Actor.prototype.finalExpRate) {
                var expRate = Game_Actor.prototype.finalExpRate;
                Game_Actor.prototype.finalExpRate = function () {
                    return expRate.apply(this, arguments) * (X.exp || 1);
                };
            }
            if (typeof Game_Troop !== 'undefined' && Game_Troop.prototype.goldTotal) {
                var goldTotal = Game_Troop.prototype.goldTotal;
                Game_Troop.prototype.goldTotal = function () {
                    return Math.round(goldTotal.apply(this, arguments) * (X.gold || 1));
                };
            }
            if (typeof BattleManager !== 'undefined' && BattleManager.processEscape) {
                var processEscape = BattleManager.processEscape;
                BattleManager.processEscape = function () {
                    if (X.escape) this._escapeRatio = 1;
                    return processEscape.apply(this, arguments);
                };
            }
        })();
    })();
    """#

    override func userScripts(for game: Game) -> [WKUserScript] {
        guard game.engine.isRPGMaker else { return [] }
        return [WKUserScript(source: CheatsFeature.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)]
    }

    override func menuItems(for game: Game) -> [UIMenuElement] {
        guard game.engine.isRPGMaker else { return [] }
        return [UIMenu(title: "Cheats", image: UIImage(systemName: "wand.and.stars"), children: [
            UIAction(title: "Cheat Engine…", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                self?.openEngine()
            },
            UIAction(title: "Heal Party", image: UIImage(systemName: "cross.case.fill")) { [weak self] _ in
                guard let self else { return }
                Task { _ = await self.run("heal") }
            },
            UIAction(title: "Save Anywhere", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                guard let self else { return }
                Task { _ = await self.run("save") }
            },
        ])]
    }

    /// Opens the cheat engine sheet. The game pauses while it is open.
    func openEngine() {
        let game = context.game()
        guard game.engine.isRPGMaker else { return }
        let model = CheatEngineModel(feature: self, game: game)
        let host = UIHostingController(rootView: CheatEngineView(model: model))
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        context.evaluate("window.__nex && window.__nex.pause()")
        model.onClose = { [weak self] in self?.context.evaluate("window.__nex && window.__nex.resume()") }
        context.present(host)
    }

    /// Calls window.__nexCheat with numbers only. Returns (worked, text): text is an error, or the count after
    /// "ok:" for commands that count (scan, give every item).
    func run(_ name: String, _ a: Double = 0, _ b: Double = 0, _ c: Double = 0, _ d: Double = 0) async -> (ok: Bool, text: String) {
        guard context.webView != nil else { return (false, "The game isn't running.") }
        let safeName = name.filter { $0.isLetter }
        func number(_ value: Double) -> String { value.isFinite ? String(value) : "0" }
        let script = "window.__nexCheat ? window.__nexCheat('\(safeName)', \(number(a)), \(number(b)), \(number(c)), \(number(d))) : 'Cheats are not ready.'"
        let result = await context.evaluateString(script) ?? "The game didn't answer."
        if result == "ok" || result.hasPrefix("ok:") {
            context.gameLog.add("cheat: \(safeName)")
            return (true, result.hasPrefix("ok:") ? String(result.dropFirst(3)) : "")
        }
        return (false, result)
    }

    func state() async -> CheatState? {
        await decode("(function () { try { return window.__nexCheatSnapshot ? window.__nexCheatSnapshot() : ''; } catch (e) { return 'error:' + e; } })()")
    }

    func catalog() async -> CheatCatalog? {
        await decode("(function () { try { return window.__nexCheatCatalog ? window.__nexCheatCatalog() : ''; } catch (e) { return 'error:' + e; } })()")
    }

    private func decode<T: Decodable>(_ script: String) async -> T? {
        guard let text = await context.evaluateString(script), !text.isEmpty else { return nil }
        if text.hasPrefix("error:") {
            context.gameLog.add("cheat engine: " + text)
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            context.gameLog.add("cheat engine: couldn't read the game's values (\(error))")
            return nil
        }
    }

    func machineNames() -> [String: String] {
        translation?.machineNames() ?? MachineTranslation.load(context.game().id)
    }

    func addMachine(_ map: [String: String]) {
        translation?.addMachine(map)
    }
}

// MARK: - Data from the page

/// A number from the game as a whole number, without trapping on huge or invalid values.
func cheatWhole(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(max(min(value, 9_000_000_000_000_000), -9_000_000_000_000_000))
}

struct CheatCatalog: Decodable {
    struct Item: Decodable {
        let kind: Int
        let id: Int
        let name: String
        let note: String
        let key: Bool
        let price: Double
        var code: String { "\(kind)-\(id)" }
    }

    struct Named: Decodable, Identifiable {
        let id: Int
        let name: String
    }

    struct Skill: Decodable, Identifiable {
        let id: Int
        let name: String
        let type: Double
    }

    let items: [Item]
    let actors: [Named]
    let skills: [Skill]
    let states: [Named]
    let maps: [Named]
    let switches: [String]
    let variables: [String]
    let params: [String]
    let currency: String

    func switchName(_ id: Int) -> String { id >= 1 && id <= switches.count ? switches[id - 1] : "" }
    func variableName(_ id: Int) -> String { id >= 1 && id <= variables.count ? variables[id - 1] : "" }

    /// Every name the engine shows, for translation.
    var allNames: [String] {
        var out: [String] = []
        out.append(contentsOf: items.map { $0.name })
        out.append(contentsOf: items.map { $0.note })
        out.append(contentsOf: actors.map { $0.name })
        out.append(contentsOf: skills.map { $0.name })
        out.append(contentsOf: states.map { $0.name })
        out.append(contentsOf: maps.map { $0.name })
        out.append(contentsOf: switches)
        out.append(contentsOf: variables)
        out.append(contentsOf: params)
        out.append(currency)
        return out
    }
}

struct CheatState: Decodable {
    struct Flags: Decodable {
        let god, oneHit, through, noEncounters, infinite, noCost, escape, crit, drop, dash: Bool
    }

    struct Member: Decodable, Identifiable {
        let id: Int
        let name: String
        let level: Int
        let maxLevel: Int
        let hp, mhp, mp, mmp, tp, exp: Double
        let job: String
        let params: [Double]
        let states: [String]
        let skills: [Int]
    }

    struct Value: Decodable {
        let n: Double
        let t: String
    }

    struct Lock: Decodable {
        let type: Double
        let id: Double
        let value: Double
        var key: String { "\(cheatWhole(type)):\(cheatWhole(id))" }
    }

    struct Enemy: Decodable, Identifiable {
        let index: Int
        let name: String
        let letter: String
        let hp, mhp: Double
        let dead: Bool
        var id: Int { index }
    }

    struct Battle: Decodable {
        let enemies: [Enemy]
    }

    struct MapInfo: Decodable {
        let id: Int
        let name: String
        let x, y, width, height: Double
    }

    struct Scan: Decodable {
        let count: Int
        let ids: [Int]
    }

    let gold: Double
    let speed: Double
    let flags: Flags
    let exp: Double
    let goldRate: Double
    let party: [Member]
    let counts: [String: Int]
    let switches: [Int]
    let variables: [String: Value]
    let locks: [Lock]
    let battle: Battle?
    let map: MapInfo?
    let scan: Scan?
    let canSave: Bool
    let canMenu: Bool

    func count(_ item: CheatCatalog.Item) -> Int { counts[item.code] ?? 0 }
    func value(_ id: Int) -> Value? { variables[String(id)] }
    func lock(type: Int, id: Int) -> Lock? { locks.first { cheatWhole($0.type) == type && cheatWhole($0.id) == id } }
}

// MARK: - Model

@MainActor
final class CheatEngineModel: ObservableObject {
    @Published var catalog: CheatCatalog?
    @Published var state: CheatState?
    @Published var loading = true
    @Published var message: String?
    @Published var toast: String?
    @Published var english: Bool {
        didSet {
            UserDefaults.standard.set(english, forKey: SettingsKey.cheatEnglish)
            if english { translateNames() }
        }
    }
    @Published var names: [String: String] = [:]
    @Published var translating = false
    @Published var pins: Set<String>
    let jobs = TranslationJobs()
    let gameID: UUID
    var onClose: () -> Void = {}
    private weak var feature: CheatsFeature?
    private var toastTask: Task<Void, Never>?

    init(feature: CheatsFeature, game: Game) {
        self.feature = feature
        self.gameID = game.id
        english = UserDefaults.standard.bool(forKey: SettingsKey.cheatEnglish)
        let stored = UserDefaults.standard.stringArray(forKey: "cheatPins.\(game.id.uuidString)") ?? []
        pins = Set(stored)
        names = feature.machineNames()
    }

    func load() async {
        if catalog == nil { catalog = await feature?.catalog() }
        state = await feature?.state()
        loading = false
        if english { translateNames() }
    }

    func reload() async {
        state = await feature?.state()
    }

    /// Battle enemies and the map change while the sheet is open.
    func translateNew() {
        if english { translateNames() }
    }

    /// Runs a command, then reads the values again.
    func run(_ name: String, _ a: Double = 0, _ b: Double = 0, _ c: Double = 0, _ d: Double = 0, done: String? = nil) {
        Task {
            guard let feature else { return }
            let result = await feature.run(name, a, b, c, d)
            if result.ok {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if let done { show(done.replacingOccurrences(of: "#", with: result.text)) }
            } else {
                message = result.text
            }
            await reload()
            translateNew()
        }
    }

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Names

    /// The English name when English is on and known, else the game's own.
    func name(_ text: String) -> String {
        guard english, let english = names[text], !english.isEmpty else { return text }
        return english
    }

    /// The game's own name under the English one.
    func original(_ text: String) -> String? {
        guard english, let english = names[text], !english.isEmpty, english != text else { return nil }
        return text
    }

    func translateNames() {
        guard let catalog, !translating else { return }
        var all = catalog.allNames
        all.append(contentsOf: state?.party.map { $0.job } ?? [])
        all.append(contentsOf: state?.battle?.enemies.map { $0.name } ?? [])
        if let here = state?.map { all.append(here.name) }
        let missing = Array(Set(all.filter { !$0.isEmpty && names[$0] == nil && MachineTranslation.needsTranslation($0) }))
        guard !missing.isEmpty else { return }
        translating = true
        let gameID = self.gameID
        jobs.translate(missing, from: MachineTranslation.guessSource(missing)) { [weak self] result in
            guard let self else { return }
            self.translating = false
            if result.isEmpty {
                if let error = self.jobs.lastError { self.message = "Names couldn't be translated: \(error)" }
                return
            }
            self.names.merge(result) { _, new in new }
            TranslationFeature.persist(result, gameID: gameID)
            self.feature?.addMachine(result)
        }
    }

    // MARK: Pins

    func isPinned(_ key: String) -> Bool { pins.contains(key) }

    func togglePin(_ key: String) {
        if pins.contains(key) { pins.remove(key) } else { pins.insert(key) }
        UserDefaults.standard.set(Array(pins).sorted(), forKey: "cheatPins.\(gameID.uuidString)")
    }
}

// MARK: - Views

struct CheatEngineView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case quick = "Quick", battle = "Battle", party = "Party", items = "Items", map = "Map"
        case switches = "Switches", variables = "Variables", scan = "Scan", pinned = "Pinned"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .quick: return "bolt.fill"
            case .battle: return "flame.fill"
            case .party: return "person.3.fill"
            case .items: return "bag.fill"
            case .map: return "map.fill"
            case .switches: return "switch.2"
            case .variables: return "number"
            case .scan: return "magnifyingglass"
            case .pinned: return "pin.fill"
            }
        }
    }

    @ObservedObject var model: CheatEngineModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .quick
    @State private var search = ""
    @State private var editing: EditRequest?
    @State private var itemKind = -1
    @State private var showUnnamed = false
    @State private var scanValue = ""
    @State private var teleport: CheatCatalog.Named?
    @State private var skillsFor: CheatState.Member?
    @State private var confirmSelfSwitches = false

    struct EditRequest: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        let apply: (Double) -> Void
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                content
            }
            .overlay(alignment: .bottom) { toastView }
            .navigationTitle("Cheat Engine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .principal) {
                    Button { model.english.toggle() } label: {
                        HStack(spacing: 4) {
                            if model.translating { ProgressView().controlSize(.mini) }
                            Image(systemName: "character.bubble")
                            Text(model.english ? "English" : "Original").font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(model.english ? NexStyle.accent.opacity(0.25) : Color.white.opacity(0.08), in: Capsule())
                    }
                    .accessibilityLabel("Show names in English")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Resume") { dismiss() } }
            }
        }
        .environment(\.colorScheme, .dark)
        .translationJobs(model.jobs)
        .task { await model.load() }
        .onDisappear { model.onClose() }
        .alert("Cheats", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.message ?? "") }
        .sheet(item: $editing) { request in
            NumberEntrySheet(title: request.title, initial: request.value) { value in request.apply(value) }
                .presentationDetents([.height(220)])
        }
        .sheet(item: $teleport) { map in
            TeleportSheet(mapName: model.name(map.name), mapID: map.id,
                          start: model.state?.map?.id == map.id ? (cheatWhole(model.state?.map?.x ?? 0), cheatWhole(model.state?.map?.y ?? 0)) : (0, 0)) { x, y in
                model.run("teleport", Double(map.id), Double(x), Double(y), done: "Teleporting when you go back to the game")
            }
            .presentationDetents([.height(300)])
        }
        .sheet(item: $skillsFor) { member in
            SkillPicker(model: model, member: member)
        }
        .confirmationDialog("Reset this map's self switches?", isPresented: $confirmSelfSwitches, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.run("selfswitches", done: "Self switches of this map reset") }
        } message: {
            Text("Events on this map (chests, people) act as if you had never touched them. Can't be undone except by loading a save.")
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                        search = ""
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(tab == item ? NexStyle.accent.opacity(0.3) : Color.white.opacity(0.07), in: Capsule())
                            .foregroundStyle(tab == item ? Color.white : Color.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var toastView: some View {
        if let text = model.toast {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var content: some View {
        if model.loading {
            Spacer()
            ProgressView()
            Spacer()
        } else if let state = model.state, let catalog = model.catalog {
            switch tab {
            case .quick: quick(state, catalog)
            case .battle: battle(state)
            case .party: party(state, catalog)
            case .items: items(state, catalog)
            case .map: map(state, catalog)
            case .switches: switches(state, catalog)
            case .variables: variables(state, catalog)
            case .scan: scan(state, catalog)
            case .pinned: pinned(state, catalog)
            }
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "wand.and.stars").font(.system(size: 40)).foregroundStyle(NexStyle.accent)
                Text("Start or load a game first").font(.headline)
                Text("The cheat engine works once you are on the map or in a battle.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await model.load() } }.buttonStyle(.bordered)
                Spacer()
            }
            .padding()
        }
    }

    // MARK: Quick

    private func quick(_ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let flags = state.flags
        let goldLock = state.lock(type: 3, id: 0)
        return List {
            Section("Money") {
                Button {
                    editing = EditRequest(title: "Gold", value: String(cheatWhole(state.gold))) { model.run("setgold", $0) }
                } label: {
                    LabeledContent {
                        Text("\(cheatWhole(state.gold)) \(model.name(catalog.currency))").monospacedDigit()
                    } label: { Label("Gold", systemImage: "dollarsign.circle.fill") }
                }
                HStack {
                    ForEach([1000, 10000, 100000, 1000000], id: \.self) { amount in
                        Button("+\(Self.short(amount))") { model.run("gold", Double(amount)) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
                Toggle(isOn: Binding(get: { goldLock != nil }, set: { model.run("lock", 3, 0, state.gold, $0 ? 1 : 0) })) {
                    Label("Keep Gold at \(cheatWhole(goldLock?.value ?? state.gold))", systemImage: "lock.fill")
                }
            }
            Section("Fights") {
                flag("God Mode", "No damage to the party", "shield.fill", flags.god, "god")
                flag("Infinite HP, MP and TP", "The party stays full", "heart.fill", flags.infinite, "infinite")
                flag("No Skill Cost", "Skills use no MP or TP", "sparkles", flags.noCost, "nocost")
                flag("One-Hit Kills", "Any damage defeats an enemy", "bolt.fill", flags.oneHit, "onehit")
                flag("Always Critical", "Party attacks always crit", "scope", flags.crit, "crit")
                flag("Always Escape", "Escape always works", "figure.run", flags.escape, "escape")
                flag("Always Drop Items", "Enemies drop everything they can", "gift.fill", flags.drop, "drop")
            }
            Section("Rewards") {
                multiplier("EXP", "chart.line.uptrend.xyaxis", state.exp, "expmul")
                multiplier("Gold", "dollarsign.circle", state.goldRate, "goldmul")
            }
            Section("Moving") {
                flag("Walk Through Walls", nil, "figure.walk", flags.through, "through")
                flag("Always Dash", nil, "hare.fill", flags.dash, "dash")
                flag("No Random Encounters", nil, "eye.slash.fill", flags.noEncounters, "encounters")
                Stepper(value: Binding(get: { state.speed }, set: { model.run("speed", $0) }), in: 1...6) {
                    Label("Walk Speed: \(cheatWhole(state.speed))", systemImage: "speedometer")
                }
            }
            Section("Actions") {
                Button { model.run("heal", done: "Party healed") } label: { Label("Heal Party", systemImage: "cross.case.fill") }
                Button {
                    if !state.canSave { model.run("enablesave") }
                    model.run("save")
                    dismiss()
                } label: { Label("Open Save Menu", systemImage: "square.and.arrow.down.fill") }
                Button {
                    model.run("menu")
                    dismiss()
                } label: { Label("Open Main Menu", systemImage: "list.bullet") }
                if !state.canSave {
                    Button { model.run("enablesave", done: "Saving allowed") } label: { Label("Allow Saving", systemImage: "lock.open.fill") }
                }
                if !state.canMenu {
                    Button { model.run("enablemenu", done: "Menu allowed") } label: { Label("Allow the Menu", systemImage: "lock.open.fill") }
                }
            }
        }
    }

    private static func short(_ amount: Int) -> String {
        amount >= 1_000_000 ? "\(amount / 1_000_000)M" : amount >= 1000 ? "\(amount / 1000)k" : "\(amount)"
    }

    private func flag(_ title: String, _ detail: String?, _ symbol: String, _ on: Bool, _ command: String) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { model.run(command, $0 ? 1 : 0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func multiplier(_ title: String, _ symbol: String, _ value: Double, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(title) ×\(value == value.rounded() ? String(cheatWhole(value)) : String(value))", systemImage: symbol)
            HStack {
                ForEach([1.0, 2, 5, 10, 50], id: \.self) { factor in
                    Button("×\(Int(factor))") { model.run(command, factor) }
                        .buttonStyle(.bordered)
                        .tint(value == factor ? NexStyle.accent : .gray)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Battle

    @ViewBuilder private func battle(_ state: CheatState) -> some View {
        if let battle = state.battle {
            List {
                Section {
                    Button { model.run("win", done: "Every enemy defeated") } label: { Label("Win Now", systemImage: "trophy.fill") }
                    Button { model.run("weaken", done: "Enemies at 1 HP") } label: { Label("Enemies to 1 HP", systemImage: "heart.slash.fill") }
                    Button { model.run("heal", done: "Party healed") } label: { Label("Heal Party", systemImage: "cross.case.fill") }
                    Button(role: .destructive) {
                        model.run("abort")
                        dismiss()
                    } label: { Label("Leave the Battle", systemImage: "door.left.hand.open") }
                } footer: {
                    Text("Win Now and the enemy buttons take effect when you go back to the game.")
                }
                Section("Enemies") {
                    ForEach(battle.enemies) { enemy in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(model.name(enemy.name) + (enemy.letter.isEmpty ? "" : " \(enemy.letter)")).font(.headline)
                                if enemy.dead { Text("Defeated").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                            }
                            bar("HP", enemy.hp, enemy.mhp, .red)
                            HStack {
                                Button("Defeat") { model.run("killenemy", Double(enemy.index)) }.buttonStyle(.bordered)
                                Button("Set HP…") {
                                    editing = EditRequest(title: "HP for \(model.name(enemy.name))", value: String(cheatWhole(enemy.hp))) {
                                        model.run("enemyhp", Double(enemy.index), $0)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.caption)
                            .disabled(enemy.dead)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        } else {
            placeholder("flame", "Not in a battle", "Open the cheat engine during a battle to see the enemies. God Mode, One-Hit Kills and the other fight cheats are in Quick.")
        }
    }

    // MARK: Party

    private func party(_ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let paramNames = (0..<8).map { index -> String in
            let defaults = ["Max HP", "Max MP", "Attack", "Defense", "M. Attack", "M. Defense", "Agility", "Luck"]
            let own = index < catalog.params.count ? catalog.params[index] : ""
            return own.isEmpty ? defaults[index] : model.name(own)
        }
        let inParty = Set(state.party.map(\.id))
        return List {
            ForEach(state.party) { member in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.name(member.name)).font(.headline)
                            if !member.job.isEmpty { Text(model.name(member.job)).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text("Lv \(member.level)").font(.subheadline.weight(.bold)).foregroundStyle(NexStyle.accent)
                        }
                        Button { edit("HP for \(model.name(member.name))", member.hp) { model.run("hp", Double(member.id), $0) } } label: { bar("HP", member.hp, member.mhp, .green) }
                            .buttonStyle(.plain)
                        Button { edit("MP for \(model.name(member.name))", member.mp) { model.run("mp", Double(member.id), $0) } } label: { bar("MP", member.mp, member.mmp, .blue) }
                            .buttonStyle(.plain)
                        Button { edit("TP for \(model.name(member.name))", member.tp) { model.run("tp", Double(member.id), $0) } } label: { bar("TP", member.tp, 100, .orange) }
                            .buttonStyle(.plain)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                Button("Level…") {
                                    edit("Level for \(model.name(member.name)) (max \(member.maxLevel))", Double(member.level)) {
                                        model.run("level", Double(member.id), $0)
                                    }
                                }
                                Button("Max Level") { model.run("level", Double(member.id), Double(member.maxLevel)) }
                                Button("EXP…") { edit("Total EXP for \(model.name(member.name))", member.exp) { model.run("exp", Double(member.id), $0) } }
                                Button("Heal") { model.run("recover", Double(member.id)) }
                                Button("Max Stats") { model.run("maxparams", Double(member.id), done: "Stats at the maximum") }
                                Button("Reset Stats") { model.run("resetparams", Double(member.id)) }
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(0..<8, id: \.self) { index in
                            let value = index < member.params.count ? member.params[index] : 0
                            Button {
                                edit("\(paramNames[index]) for \(model.name(member.name))", value) {
                                    model.run("param", Double(member.id), Double(index), $0)
                                }
                            } label: {
                                HStack {
                                    Text(paramNames[index]).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text("\(cheatWhole(value))").font(.callout.monospacedDigit())
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        skillsFor = member
                    } label: {
                        LabeledContent("Skills", value: "\(member.skills.count) learned")
                    }
                    if !member.states.isEmpty {
                        HStack {
                            Text("States: " + member.states.map { model.name($0) }.joined(separator: ", ")).font(.caption).lineLimit(2)
                            Spacer()
                            Button("Clear") { model.run("clearstates", Double(member.id)) }.buttonStyle(.bordered).font(.caption)
                        }
                    }
                }
            }
            Section {
                ForEach(catalog.actors) { actor in
                    Toggle(isOn: Binding(get: { inParty.contains(actor.id) },
                                         set: { model.run($0 ? "addactor" : "removeactor", Double(actor.id)) })) {
                        nameLabel(actor.name, "#\(actor.id)")
                    }
                }
            } header: {
                Text("Who Is in the Party")
            } footer: {
                Text("Adding someone the story hasn't introduced yet can confuse the game's events.")
            }
        }
    }

    private func edit(_ title: String, _ value: Double, apply: @escaping (Double) -> Void) {
        editing = EditRequest(title: title, value: String(cheatWhole(value)), apply: apply)
    }

    private func bar(_ title: String, _ value: Double, _ maximum: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption2.weight(.bold)).frame(width: 22, alignment: .leading)
            ProgressView(value: maximum > 0 ? min(max(value / maximum, 0), 1) : 0).tint(color)
            Text("\(cheatWhole(value))/\(cheatWhole(maximum))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: Lists

    private func matches(_ text: String, _ id: Int) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }
        if String(id) == query { return true }
        if text.localizedCaseInsensitiveContains(query) { return true }
        if let english = model.names[text], english.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    private func searchField(_ prompt: String = "Search by name or ID") -> some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func nameLabel(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name.isEmpty ? detail : model.name(name)).lineLimit(1)
            HStack(spacing: 6) {
                Text(detail)
                if let original = model.original(name) { Text(original).lineLimit(1) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func items(_ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let kinds = ["Item", "Weapon", "Armor"]
        let list = catalog.items.filter { item in
            (itemKind == -1 || (itemKind == 3 ? item.key : item.kind == itemKind && !(itemKind == 0 && item.key)))
                && matches(item.name, item.id)
        }
        return VStack(spacing: 0) {
            Picker("Kind", selection: $itemKind) {
                Text("All").tag(-1)
                Text("Items").tag(0)
                Text("Weapons").tag(1)
                Text("Armor").tag(2)
                Text("Key").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            searchField()
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Button("99 of Every Item") { model.run("allitems", 0, 99, 0, done: "# kinds of items added") }
                            Button("Every Weapon") { model.run("allitems", 1, 1, done: "# weapons added") }
                            Button("Every Armor") { model.run("allitems", 2, 1, done: "# armors added") }
                            Button("+ Key Items") { model.run("allitems", 0, 1, 1, done: "# kinds added") }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
                ForEach(list, id: \.code) { item in
                    let count = state.count(item)
                    let lockType = 4 + item.kind
                    let lock = state.lock(type: lockType, id: item.id)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if lock != nil { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange) }
                                Text(model.name(item.name)).lineLimit(1)
                            }
                            HStack(spacing: 6) {
                                Text("\(item.key ? "Key item" : kinds[min(max(item.kind, 0), 2)]) #\(item.id)")
                                if let original = model.original(item.name) { Text(original).lineLimit(1) }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.run("setitem", Double(item.kind), Double(item.id), Double(max(count - 1, 0))) } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            editing = EditRequest(title: "How many \(model.name(item.name))?", value: String(count)) {
                                model.run("setitem", Double(item.kind), Double(item.id), $0)
                            }
                        } label: {
                            Text("\(count)").font(.body.monospacedDigit()).frame(minWidth: 34)
                        }
                        .buttonStyle(.borderless)
                        Button { model.run("setitem", Double(item.kind), Double(item.id), Double(count + 1)) } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
                    .contextMenu {
                        Button { model.run("setitem", Double(item.kind), Double(item.id), 99) } label: { Label("Set to 99", systemImage: "arrow.up.to.line") }
                        Button {
                            model.run("lock", Double(lockType), Double(item.id), Double(max(count, 1)), lock == nil ? 1 : 0)
                        } label: { Label(lock == nil ? "Keep at \(max(count, 1))" : "Stop Keeping", systemImage: lock == nil ? "lock.fill" : "lock.open") }
                        if !item.note.isEmpty { Text(model.name(item.note)) }
                    }
                }
            }
        }
    }

    // MARK: Map

    private func map(_ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let list = catalog.maps.filter { matches($0.name, $0.id) }
        return VStack(spacing: 0) {
            if let here = state.map {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(here.name.isEmpty ? "Map \(here.id)" : model.name(here.name)).font(.headline)
                        Text("Map #\(here.id) · x \(cheatWhole(here.x)), y \(cheatWhole(here.y)) · \(cheatWhole(here.width))×\(cheatWhole(here.height))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset Events") { confirmSelfSwitches = true }.buttonStyle(.bordered).font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            searchField("Search maps")
            List(list) { map in
                Button { teleport = map } label: {
                    HStack {
                        nameLabel(map.name, "Map #\(map.id)")
                        Spacer()
                        if state.map?.id == map.id { Text("Here").font(.caption).foregroundStyle(NexStyle.accent) }
                        Image(systemName: "location.fill").foregroundStyle(NexStyle.accent)
                    }
                }
            }
        }
    }

    // MARK: Switches and variables

    private func switches(_ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let on = Set(state.switches)
        let ids = (1...max(catalog.switches.count, 1)).filter { id in
            id <= catalog.switches.count && (showUnnamed || !catalog.switchName(id).isEmpty || on.contains(id))
                && matches(catalog.switchName(id), id)
        }
        return VStack(spacing: 0) {
            searchField()
            Toggle("Show Unnamed Switches", isOn: $showUnnamed).font(.caption).padding(.horizontal, 16).padding(.bottom, 4)
            List(ids, id: \.self) { id in switchRow(id, on.contains(id), state, catalog) }
        }
    }

    private func switchRow(_ id: Int, _ on: Bool, _ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let lock = state.lock(type: 2, id: id)
        let key = "s:\(id)"
        return Toggle(isOn: Binding(get: { on }, set: { model.run("switch", Double(id), $0 ? 1 : 0) })) {
            HStack(spacing: 4) {
                if lock != nil { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange) }
                if model.isPinned(key) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(NexStyle.accent) }
                nameLabel(catalog.switchName(id), "Switch #\(id)")
            }
        }
        .contextMenu {
            Button { model.togglePin(key) } label: { Label(model.isPinned(key) ? "Unpin" : "Pin", systemImage: "pin") }
            Button { model.run("lock", 2, Double(id), on ? 1 : 0, lock == nil ? 1 : 0) } label: {
                Label(lock == nil ? "Keep \(on ? "On" : "Off")" : "Stop Keeping", systemImage: lock == nil ? "lock.fill" : "lock.open")
            }
        }
    }

    private func variables(_ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let ids = (1...max(catalog.variables.count, 1)).filter { id in
            id <= catalog.variables.count && (showUnnamed || !catalog.variableName(id).isEmpty || state.value(id) != nil)
                && matches(catalog.variableName(id), id)
        }
        return VStack(spacing: 0) {
            searchField()
            Toggle("Show Unnamed Variables", isOn: $showUnnamed).font(.caption).padding(.horizontal, 16).padding(.bottom, 4)
            List(ids, id: \.self) { id in variableRow(id, state, catalog) }
        }
    }

    private func variableRow(_ id: Int, _ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let value = state.value(id)
        let text = value?.t ?? "0"
        let lock = state.lock(type: 1, id: id)
        let key = "v:\(id)"
        let title = catalog.variableName(id).isEmpty ? "Variable #\(id)" : model.name(catalog.variableName(id))
        return Button {
            editing = EditRequest(title: title, value: text) { model.run("variable", Double(id), $0) }
        } label: {
            HStack {
                if lock != nil { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange) }
                if model.isPinned(key) { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(NexStyle.accent) }
                nameLabel(catalog.variableName(id), "Variable #\(id)").foregroundStyle(.primary)
                Spacer()
                Text(text).font(.body.monospacedDigit()).lineLimit(1).foregroundStyle(NexStyle.accent)
            }
        }
        .contextMenu {
            Button { model.togglePin(key) } label: { Label(model.isPinned(key) ? "Unpin" : "Pin", systemImage: "pin") }
            Button { model.run("lock", 1, Double(id), value?.n ?? 0, lock == nil ? 1 : 0) } label: {
                Label(lock == nil ? "Keep at \(text)" : "Stop Keeping", systemImage: lock == nil ? "lock.fill" : "lock.open")
            }
        }
    }

    // MARK: Scan

    private func scan(_ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let number = Double(scanValue.trimmingCharacters(in: .whitespaces))
        return List {
            Section {
                TextField("Value you see in the game (e.g. 120)", text: $scanValue)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.title3.monospacedDigit())
                HStack {
                    Button("New Scan") { if let number { model.run("scan", 1, number, done: "# variables match") } }
                        .disabled(number == nil)
                    Button("Next: =") { if let number { model.run("scan", 2, number, done: "# left") } }
                        .disabled(number == nil || state.scan == nil)
                }
                .buttonStyle(.borderedProminent)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("Went Up") { model.run("scan", 3, done: "# left") }
                        Button("Went Down") { model.run("scan", 4, done: "# left") }
                        Button("Changed") { model.run("scan", 5, done: "# left") }
                        Button("Same") { model.run("scan", 6, done: "# left") }
                        Button("Reset", role: .destructive) { model.run("scan", 7) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.scan == nil)
                }
            } footer: {
                Text("Like Cheat Engine: scan for a number the game shows (money, a counter, affection), play until it changes, then scan again with the new number or with Went Up / Went Down. The variables left are the ones that hold it. Tap one to change it.")
            }
            if let result = state.scan {
                Section("\(result.count) Found" + (result.count > result.ids.count ? " (first \(result.ids.count))" : "")) {
                    ForEach(result.ids, id: \.self) { id in variableRow(id, state, catalog) }
                }
            }
        }
    }

    // MARK: Pinned

    private func pinned(_ state: CheatState, _ catalog: CheatCatalog) -> some View {
        let pins = model.pins.sorted { a, b in
            let ka = a.first ?? "v", kb = b.first ?? "v"
            if ka != kb { return ka < kb }
            return (Int(a.dropFirst(2)) ?? 0) < (Int(b.dropFirst(2)) ?? 0)
        }
        let on = Set(state.switches)
        return List {
            if pins.isEmpty && state.locks.isEmpty {
                Section {
                    Text("Touch and hold a switch or variable and choose Pin to keep it here. Keep (lock) holds a value while you play.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !pins.isEmpty {
                Section("Pinned") {
                    ForEach(pins, id: \.self) { key in
                        let id = Int(key.dropFirst(2)) ?? 0
                        if key.hasPrefix("s:") { switchRow(id, on.contains(id), state, catalog) } else { variableRow(id, state, catalog) }
                    }
                }
            }
            if !state.locks.isEmpty {
                Section {
                    ForEach(state.locks, id: \.key) { lock in
                        HStack {
                            Image(systemName: "lock.fill").foregroundStyle(.orange)
                            Text(lockTitle(lock, catalog)).lineLimit(1)
                            Spacer()
                            Text(cheatWhole(lock.type) == 2 ? (lock.value != 0 ? "On" : "Off") : "\(cheatWhole(lock.value))").monospacedDigit()
                            Button { model.run("lock", lock.type, lock.id, lock.value, 0) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Stop Keeping All", role: .destructive) { model.run("unlockall") }
                } header: {
                    Text("Kept Values")
                } footer: {
                    Text("Kept values are set again 4 times a second until the game restarts.")
                }
            }
        }
    }

    private func lockTitle(_ lock: CheatState.Lock, _ catalog: CheatCatalog) -> String {
        let id = cheatWhole(lock.id)
        switch cheatWhole(lock.type) {
        case 1: return catalog.variableName(id).isEmpty ? "Variable #\(id)" : model.name(catalog.variableName(id))
        case 2: return catalog.switchName(id).isEmpty ? "Switch #\(id)" : model.name(catalog.switchName(id))
        case 3: return "Gold"
        default:
            let kind = cheatWhole(lock.type) - 4
            let item = catalog.items.first { $0.kind == kind && $0.id == id }
            return item.map { model.name($0.name) } ?? "Item #\(id)"
        }
    }

    private func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(NexStyle.accent)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }
}

/// Teleport: the spot on the chosen map.
private struct TeleportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mapName: String
    let mapID: Int
    let start: (Int, Int)
    let onGo: (Int, Int) -> Void
    @State private var x = ""
    @State private var y = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Teleport to \(mapName.isEmpty ? "Map \(mapID)" : mapName)").font(.headline).multilineTextAlignment(.center)
            HStack {
                field("X", $x)
                field("Y", $y)
            }
            Text("If the spot is inside a wall, turn on Walk Through Walls in Quick.").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("Teleport") {
                    onGo(Int(x) ?? 0, Int(y) ?? 0)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .onAppear {
            x = String(start.0)
            y = String(start.1)
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .keyboardType(.numberPad)
                .font(.title3.monospacedDigit())
                .padding(10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Learn and forget skills for one party member.
private struct SkillPicker: View {
    @ObservedObject var model: CheatEngineModel
    let member: CheatState.Member
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var learnedOnly = false

    var body: some View {
        NavigationStack {
            let learned = Set(currentSkills)
            let list = (model.catalog?.skills ?? []).filter { skill in
                (!learnedOnly || learned.contains(skill.id))
                    && (search.isEmpty || skill.name.localizedCaseInsensitiveContains(search)
                        || (model.names[skill.name]?.localizedCaseInsensitiveContains(search) ?? false) || String(skill.id) == search)
            }
            List {
                Section {
                    Toggle("Learned Only", isOn: $learnedOnly)
                    HStack {
                        Button("Learn Class Skills") { model.run("learnclass", Double(member.id), done: "Class skills learned") }
                        Button("Learn Every Skill") { model.run("learnall", Double(member.id), done: "Every skill learned") }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                ForEach(list) { skill in
                    Toggle(isOn: Binding(get: { learned.contains(skill.id) },
                                         set: { model.run($0 ? "learn" : "forget", Double(member.id), Double(skill.id)) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name(skill.name)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text("#\(skill.id)")
                                if let original = model.original(skill.name) { Text(original).lineLimit(1) }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Skills of \(model.name(member.name))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .environment(\.colorScheme, .dark)
    }

    private var currentSkills: [Int] {
        model.state?.party.first { $0.id == member.id }?.skills ?? member.skills
    }
}
