"""Life checklist (SPEC top table) from analysed data. Dutch report, machine-readable JSON.

Each criterion gets status 'ja' (shown by data), 'deels' (partially), 'nee' (not shown) and
the numbers + snapshot steps that prove it.  Thresholds are deliberately explicit.
"""
import os

import numpy as np
from scipy import stats as sst

import ocio

MIN_SYN_PER_CELL = 5        # attributed syntheses needed to call a cell metabolically active
GROWTH_MIN_REL = 0.15       # relative lipid increase for 'growth'
GROWTH_P = 0.05
BILAYER_RANGE = (0.2, 0.65)  # fraction of wall heads facing the lumen


def _fmt(v, nd=1):
    if isinstance(v, (int, np.integer)):
        return ocio.fmt_int_nl(v)
    return ocio.fmt_float_nl(float(v), nd)


def _lin(x, y):
    x = np.asarray(x, float); y = np.asarray(y, float)
    if len(x) < 3 or np.ptp(x) == 0:
        return dict(slope=0.0, p=1.0, r=0.0)
    r = sst.linregress(x, y)
    return dict(slope=float(r.slope), p=float(r.pvalue), r=float(r.rvalue))


def evaluate(rundir, params, frames, tracks, tevents, events, ev_summary, tcfg):
    K = len(frames)
    steps = [f["step"] for f in frames]
    snap_every = (steps[1] - steps[0]) if K > 1 else 1
    synthetic = bool(params.get("synthetic", 0))
    init = str(params.get("init", "onbekend"))
    m = tcfg["confirm_frames"]
    caveats = []
    if synthetic:
        caveats.append("SYNTHETISCHE TESTDATA (tools/make_synthetic.py) - dit is GEEN simulatie; "
                       "de uitkomsten zeggen alleen iets over de analysesoftware.")
    if init != "soup":
        caveats.append(f"init = {init}: membranen zijn (deels) geplaatst; criterium 1 telt dan niet als zelf-assemblage.")
    nZ = sum(f["counts"].get("Z", 0) for f in frames)
    fallback = nZ > 0 or str(params.get("division", params.get("division_mode", ""))).lower() in ("fallback", "ftsz", "z")
    mech = "terugvalmechanisme (Z-ring, SPEC par. 6)" if fallback else "emergent (geen Z-deeltjes aanwezig)"
    if fallback:
        caveats.append("Deling gebruikt het terugvalmechanisme met Z-deeltjes (FtsZ-achtige ring), geen spontane splitsing.")

    tr = {t["id"]: t for t in tracks}
    real = [t for t in tracks if not t["fragment"]]

    # ---------------------------------------------------------------- 1 boundary
    n_with = sum(1 for f in frames if f["cells"])
    first_cell = next((f for f in frames if f["cells"]), None)
    obs_inner = [c["inner_frac"] for f in frames for c in f["cells"] if c["inner_heads"] + c["outer_heads"] >= 10]
    bil_ok = [BILAYER_RANGE[0] <= v <= BILAYER_RANGE[1] for v in obs_inner]
    denovo = [t for t in real if t["start_reason"] == "nieuw gevormd" and t["n_frames"] >= m]
    at_start = [t for t in real if t["start_reason"] == "aanwezig bij start"]
    first0 = frames[0]
    c1 = dict(id=1, naam="Grens (membraan)", status="nee", samenvatting="geen gesloten membraan gevonden", bewijs={})
    if first_cell is not None:
        ev = dict(snapshots_met_cel=n_with, snapshots_totaal=K, eerste_cel_stap=first_cell["step"],
                  cellen_in_eerste_snapshot=len(first0["cells"]), eerste_snapshot_stap=first0["step"],
                  max_gelijktijdig=max(len(f["cells"]) for f in frames),
                  bilaag_fractie_binnenkoppen_mediaan=round(float(np.median(obs_inner)), 3) if obs_inner else None,
                  bilaag_ok_fractie=round(float(np.mean(bil_ok)), 3) if bil_ok else None,
                  nieuw_gevormde_cellen=len(denovo))
        if denovo:
            t = min(denovo, key=lambda t: t["start_step"])
            s = t["series"]
            ev["voorbeeld"] = dict(spoor=t["id"], stap=t["start_step"], lipiden=s["n_lipids"][0],
                                   lumen_oppervlak=s["area"][0], binnenkop_fractie=s["inner_frac"][0],
                                   blijft_bestaan_snapshots=t["n_frames"])
        bil = ev["bilaag_ok_fractie"] or 0
        self_asm = init == "soup" and (len(first0["cells"]) == 0 or first0["step"] > 0) and (denovo or at_start)
        if self_asm and bil >= 0.8:
            c1["status"] = "ja"
        else:
            c1["status"] = "deels"
        c1["samenvatting"] = (f"{len(denovo)} cellen zelf gevormd (eerste cel bij stap {_fmt(first_cell['step'])}); "
                              f"{_fmt(100 * bil, 0)}% van de waarnemingen heeft een dubbellaag-opbouw")
        if init != "soup":
            c1["samenvatting"] += f" - maar init = {init} (geplaatst)"
        c1["bewijs"] = ev
        c1["stappen"] = sorted({t["start_step"] for t in denovo})[:10]

    # ---------------------------------------------------------------- 2 metabolism
    c2 = dict(id=2, naam="Metabolisme", status="nee", samenvatting="geen synthese-gebeurtenissen in cellen", bewijs={})
    syn = ev_summary.get("syn")
    if syn:
        act = sorted([t for t in real if t["events"].get("syn", 0) >= MIN_SYN_PER_CELL],
                     key=lambda t: -t["events"].get("syn", 0))
        inc = ev_summary.get("syn_incorporation", {})
        ev = dict(syn_totaal=syn["total"], syn_in_lumen=syn["in_cells"], syn_bij_cel=syn["near_cells"],
                  fractie_in_lumen=round(syn["in_cells"] / max(syn["total"], 1), 3),
                  actieve_cellen=len(act), inbouw=inc)
        if act:
            t = act[0]
            s = t["series"]
            ev["voorbeeld"] = dict(spoor=t["id"], syntheses=t["events"].get("syn", 0),
                                   syn_a=t["events"].get("syn_a", 0), syn_b=t["events"].get("syn_b", 0),
                                   van_stap=t["start_step"], tot_stap=t["end_step"],
                                   katalysatoren_gem=round(float(np.mean(np.array(s["n_Ka"]) + np.array(s["n_Kb"]))), 1))
        inc_ok = inc.get("lipid_bead_tracked", 0) > 0 and inc.get("into_same_cell_membrane", 0) > 0
        if act and (inc_ok or inc.get("lipid_bead_tracked", 0) == 0):
            c2["status"] = "ja"
        elif syn["in_cells"] > 0:
            c2["status"] = "deels"
        msg = (f"{_fmt(syn['in_cells'])} van {_fmt(syn['total'])} lipide-syntheses gebeurden in een lumen; "
               f"{len(act)} cellen met >= {MIN_SYN_PER_CELL}")
        if inc.get("lipid_bead_tracked", 0) > 0:
            msg += (f"; {_fmt(inc['into_same_cell_membrane'])}/{_fmt(inc['lipid_bead_tracked'])} nieuwe lipiden "
                    f"zitten in de volgende snapshot in het membraan van dezelfde cel")
        else:
            msg += "; inbouw in het membraan niet controleerbaar (event-index is geen lipidekraal)"
        c2["samenvatting"] = msg
        c2["bewijs"] = ev
        c2["stappen"] = [t["start_step"] for t in act[:5]]

    # ---------------------------------------------------------------- 3 growth
    growing = []
    for t in real:
        s = t["series"]
        if t["n_frames"] < 4:
            continue
        li = _lin(s["step"], s["n_lipids"]); ar = _lin(s["step"], s["area"])
        rel = (max(s["n_lipids"]) - s["n_lipids"][0]) / max(s["n_lipids"][0], 1)
        rel_a = (max(s["area"]) - s["area"][0]) / max(s["area"][0], 1e-9)
        t["_growth"] = dict(lip=li, area=ar, rel=rel, rel_area=rel_a)
        if li["slope"] > 0 and li["p"] < GROWTH_P and ar["slope"] > 0 and ar["p"] < GROWTH_P and rel >= GROWTH_MIN_REL:
            growing.append(t)
    c3 = dict(id=3, naam="Groei", status="nee", samenvatting="geen cel met significante groei", bewijs={})
    if growing:
        t = max(growing, key=lambda t: t["_growth"]["rel"])
        s = t["series"]
        imax = int(np.argmax(s["n_lipids"]))
        c3["status"] = "ja"
        c3["bewijs"] = dict(groeiende_cellen=len(growing), voorbeeld=dict(
            spoor=t["id"], van_stap=s["step"][0], tot_stap=s["step"][imax],
            lipiden_van=s["n_lipids"][0], lipiden_tot=s["n_lipids"][imax],
            oppervlak_van=s["area"][0], oppervlak_tot=s["area"][imax],
            p_lipiden=float(f"{t['_growth']['lip']['p']:.2g}"), p_oppervlak=float(f"{t['_growth']['area']['p']:.2g}"),
            syntheses=t["events"].get("syn", 0), eindigt=t["end_reason"]))
        c3["samenvatting"] = (f"{len(growing)} cellen groeien significant; bv. spoor {t['id']}: "
                              f"{s['n_lipids'][0]} -> {s['n_lipids'][imax]} lipiden, lumen {_fmt(s['area'][0])} -> "
                              f"{_fmt(s['area'][imax])} (stap {_fmt(s['step'][0])}-{_fmt(s['step'][imax])})")
        c3["stappen"] = [s["step"][0], s["step"][imax]]

    # ---------------------------------------------------------------- 4 reproduction
    divs = [e for e in tevents if e["kind"] == "deling"]
    good = []
    detail = []
    frame_by_step = {f["step"]: f for f in frames}
    for e in divs:
        kids = [tr[c] for c in e["children"]]
        own = []
        cat = []
        for c in kids:
            cat.append(all((a + b) > 0 for a, b in zip(c["series"]["n_Ka"][:m], c["series"]["n_Kb"][:m])))
        # own membrane: daughters in different aggregates at some common frame within m frames
        own_ok = False
        for j in range(m + 1):
            ags = []
            for c in kids:
                if j < c["n_frames"]:
                    st = c["series"]["step"][j]
                    f = frame_by_step[st]
                    cl = next((x for x in f["cells"] if x.get("track") == c["id"]), None)
                    if cl is not None:
                        ags.append((st, cl["agg"]))
            sts = {a[0] for a in ags}
            if len(ags) == len(kids) and len(sts) == 1 and len({a[1] for a in ags}) == len(kids):
                own_ok = True
                break
        p = tr[e["parents"][0]]
        d = dict(stap=e["step"], ouder=p["id"], dochters=e["children"], bevestigd=e["confirmed"],
                 eigen_membraan=own_ok, katalysatoren_in_elke_dochter=all(cat),
                 ouder_Ka=p["series"]["n_Ka"][-1], ouder_Kb=p["series"]["n_Kb"][-1],
                 dochters_Ka=[c["series"]["n_Ka"][0] for c in kids], dochters_Kb=[c["series"]["n_Kb"][0] for c in kids],
                 dochters_levensduur_snapshots=[c["n_frames"] for c in kids])
        detail.append(d)
        if e["confirmed"] and own_ok and all(cat):
            good.append(d)
    c4 = dict(id=4, naam="Voortplanting", status="nee", samenvatting="geen deling waargenomen",
              bewijs=dict(delingen=detail, mechanisme=mech,
                          max_generatie=max([t["generation"] or 0 for t in tracks], default=0)))
    if good:
        c4["status"] = "ja"
        g = good[0]
        c4["samenvatting"] = (f"{len(good)} bevestigde delingen met eigen gesloten membraan en katalysatoren in beide "
                              f"dochters (eerste bij stap {_fmt(g['stap'])}: spoor {g['ouder']} -> {g['dochters']}); "
                              f"mechanisme: {mech}")
        c4["stappen"] = [d["stap"] for d in good[:10]]
    elif divs:
        c4["status"] = "deels"
        c4["samenvatting"] = (f"{len(divs)} splitsingen, maar geen enkele voldoet aan alle eisen "
                              f"(bevestigd + eigen membraan + katalysatoren in beide dochters); mechanisme: {mech}")
        c4["stappen"] = [d["stap"] for d in detail[:10]]

    # ---------------------------------------------------------------- 5 heredity + selection
    fr_steps = np.array(steps, float)
    ka_in = np.array([sum(c["n_Ka"] for c in f["cells"]) for f in frames], float)
    kb_in = np.array([sum(c["n_Kb"] for c in f["cells"]) for f in frames], float)
    tot = ka_in + kb_in
    share = np.where(tot > 0, kb_in / np.maximum(tot, 1), np.nan)
    ok = np.isfinite(share)
    first_b = int(np.argmax(kb_in > 0)) if (kb_in > 0).any() else None
    sel = dict(kb_aandeel_in_cellen_per_snapshot=[None if not np.isfinite(v) else round(float(v), 3) for v in share])
    rising = False
    if first_b is not None and ok[first_b:].sum() >= 4:
        xs = fr_steps[first_b:][ok[first_b:]]; ys = share[first_b:][ok[first_b:]]
        tau, p_tau = sst.kendalltau(xs, ys)
        li = _lin(xs, ys)
        sel.update(eerste_kb_in_cel_stap=int(steps[first_b]), aandeel_begin=round(float(ys[0]), 3),
                   aandeel_eind=round(float(ys[-1]), 3), aandeel_max=round(float(np.max(ys)), 3),
                   kendall_tau=round(float(tau), 3), p=float(f"{p_tau:.2g}"), helling_per_1e6_stappen=round(li["slope"] * 1e6, 4))
        rising = tau > 0 and p_tau < 0.05 and (ys[-1] - ys[0]) >= 0.05
    # global share from stats.csv
    st = ocio.read_stats(rundir)
    if len(st) and {"nKa", "nKb"} <= set(st.columns):
        g = st["nKb"] / (st["nKa"] + st["nKb"]).replace(0, np.nan)
        sel["kb_aandeel_totaal_begin"] = None if not np.isfinite(g.iloc[0]) else round(float(g.iloc[0]), 3)
        sel["kb_aandeel_totaal_eind"] = None if not np.isfinite(g.iloc[-1]) else round(float(g.iloc[-1]), 3)
    inherit = [d for d in detail if d["katalysatoren_in_elke_dochter"]]
    var_kept = [d for d in detail if (d["ouder_Kb"] > 0) == (sum(d["dochters_Kb"]) > 0)
                and (d["ouder_Ka"] > 0) == (sum(d["dochters_Ka"]) > 0)]
    # growth rate vs Kb fraction per track
    rates, fb = [], []
    for t in real:
        s = t["series"]
        if t["n_frames"] >= 4 and "_growth" in t:
            k_tot = np.array(s["n_Ka"]) + np.array(s["n_Kb"])
            if k_tot.mean() > 0:
                rates.append(t["_growth"]["lip"]["slope"] / max(np.mean(s["n_lipids"]), 1))
                fb.append(float(np.sum(s["n_Kb"]) / max(np.sum(k_tot), 1)))
    if len(rates) >= 5:
        rho, prho = sst.spearmanr(fb, rates)
        sel["spearman_kb_fractie_vs_groeisnelheid"] = dict(rho=round(float(rho), 3), p=float(f"{prho:.2g}"), n=len(rates))
    c5 = dict(id=5, naam="Erfelijkheid + selectie", status="nee", bewijs=dict(
        delingen_met_katalysatoren_in_beide_dochters=len(inherit), delingen_varianten_doorgegeven=len(var_kept),
        selectie=sel), samenvatting="")
    parts = []
    if inherit:
        parts.append(f"{len(inherit)} delingen geven katalysatoren door aan beide dochters")
    else:
        parts.append("geen deling met katalysatoren in beide dochters")
    if "aandeel_begin" in sel:
        parts.append(f"Kb-aandeel in cellen {_fmt(100 * sel['aandeel_begin'], 0)}% -> {_fmt(100 * sel['aandeel_eind'], 0)}% "
                     f"(Kendall tau = {_fmt(sel['kendall_tau'], 2)}, p = {sel['p']:.2g})")
    else:
        parts.append("Kb (snelle variant) nog niet (genoeg) in cellen aanwezig")
    c5["samenvatting"] = "; ".join(parts)
    c5["status"] = "ja" if (inherit and rising) else ("deels" if (inherit or rising) else "nee")
    c5["stappen"] = ([sel["eerste_kb_in_cel_stap"]] if "eerste_kb_in_cel_stap" in sel else []) + [d["stap"] for d in inherit[:5]]

    # ---------------------------------------------------------------- 6 death
    # lipid growth per frame-step with / without catalysts
    dl_with, dl_without = [], []
    dying = []
    for t in real:
        s = t["series"]
        n = t["n_frames"]
        kt = np.array(s["n_Ka"]) + np.array(s["n_Kb"])
        lip = np.array(s["n_lipids"], float)
        stp = np.array(s["step"], float)
        for j in range(n - 1):
            rate = (lip[j + 1] - lip[j]) / max(stp[j + 1] - stp[j], 1) * 1e5
            (dl_with if kt[j] > 0 else dl_without).append(rate)
        had = np.nonzero(kt > 0)[0]
        if len(had) and had[0] < n - 1:
            lost = [j for j in range(had[0] + 1, n) if kt[j] == 0 and np.all(kt[j:] == 0)]
            if lost:
                j0 = lost[0]
                after = _lin(stp[j0:], lip[j0:]) if n - j0 >= 3 else dict(slope=0.0, p=1.0)
                before = _lin(stp[:j0 + 1], lip[:j0 + 1]) if j0 >= 2 else dict(slope=float("nan"), p=1.0)
                decayed = t["end_reason"] == "verdwenen" or (lip[-1] <= 0.9 * lip[j0:].max())
                dying.append(dict(spoor=t["id"], katalysatoren_weg_stap=int(stp[j0]), einde_stap=int(stp[-1]),
                                  einde=t["end_reason"], lipiden_bij_verlies=int(lip[j0]), lipiden_eind=int(lip[-1]),
                                  oppervlak_bij_verlies=s["area"][j0], oppervlak_eind=s["area"][-1],
                                  groei_na_verlies_per_1e5=round(after["slope"] * 1e5, 2),
                                  groei_voor_verlies_per_1e5=None if not np.isfinite(before["slope"]) else round(before["slope"] * 1e5, 2),
                                  stopt_met_groeien=after["slope"] * 1e5 <= 0.5 * max(1e-9, abs(np.mean(dl_with) if dl_with else 1)),
                                  vergaat=bool(decayed)))
    c6 = dict(id=6, naam="Dood", status="nee", samenvatting="geen cel die zijn katalysatoren verliest",
              bewijs=dict(lipidegroei_per_1e5_stappen_met_katalysator=round(float(np.mean(dl_with)), 2) if dl_with else None,
                          lipidegroei_per_1e5_stappen_zonder_katalysator=round(float(np.mean(dl_without)), 2) if dl_without else None,
                          n_met=len(dl_with), n_zonder=len(dl_without), cellen_katalysator_verloren=dying,
                          verdwenen_sporen=[t["id"] for t in real if t["end_reason"] == "verdwenen" and t["n_frames"] >= m]))
    full = [d for d in dying if d["stopt_met_groeien"] and d["vergaat"]]
    if full:
        d = full[0]
        c6["status"] = "ja"
        c6["samenvatting"] = (f"{len(full)} cellen verliezen hun katalysatoren, stoppen met groeien en vergaan; bv. spoor "
                              f"{d['spoor']}: katalysatoren weg bij stap {_fmt(d['katalysatoren_weg_stap'])}, "
                              f"{d['lipiden_bij_verlies']} -> {d['lipiden_eind']} lipiden, einde: {d['einde']} "
                              f"(stap {_fmt(d['einde_stap'])})")
        c6["stappen"] = [d["katalysatoren_weg_stap"], d["einde_stap"]]
    elif dying:
        c6["status"] = "deels"
        c6["samenvatting"] = f"{len(dying)} cellen verliezen hun katalysatoren, maar verval is (nog) niet aangetoond"
        c6["stappen"] = [d["katalysatoren_weg_stap"] for d in dying[:5]]
    if dl_with and dl_without:
        c6["samenvatting"] += (f"; gemiddelde lipidegroei met katalysator {_fmt(np.mean(dl_with), 2)}, zonder "
                               f"{_fmt(np.mean(dl_without), 2)} per 100.000 stappen")

    # ---------------------------------------------------------------- engine validation (context)
    val = {}
    if len(st):
        if "T_kin" in st.columns:
            val["T_kin_gemiddeld"] = round(float(st["T_kin"].mean()), 4)
            val["T_kin_min_max"] = [round(float(st["T_kin"].min()), 4), round(float(st["T_kin"].max()), 4)]
        if "max_bond" in st.columns:
            val["max_binding"] = round(float(st["max_bond"].max()), 3)
    crit = [c1, c2, c3, c4, c5, c6]
    for c in crit:
        c.setdefault("stappen", [])
    return dict(run=os.path.basename(os.path.abspath(rundir)), synthetisch=synthetic, init=init,
                delingsmechanisme=mech, snapshots=K, stap_eerste=steps[0], stap_laatste=steps[-1],
                snapshot_interval=snap_every, cel_waarnemingen=int(sum(len(f["cells"]) for f in frames)),
                sporen=len(real), fragmenten=len(tracks) - len(real), validatie=val, kanttekeningen=caveats,
                criteria=crit, n_ja=sum(c["status"] == "ja" for c in crit))


def _np(o):
    if isinstance(o, np.bool_):
        return bool(o)
    if isinstance(o, np.integer):
        return int(o)
    if isinstance(o, np.floating):
        return float(o)
    return str(o)


def to_markdown(res):
    L = []
    L.append(f"# Levenschecklist - run `{res['run']}`\n")
    if res["synthetisch"]:
        L.append("> **LET OP: SYNTHETISCHE TESTDATA - geen simulatie.** Deze uitkomst test alleen de analysesoftware.\n")
    L.append(f"- snapshots: {res['snapshots']} (stap {ocio.fmt_int_nl(res['stap_eerste'])} - "
             f"{ocio.fmt_int_nl(res['stap_laatste'])}, interval {ocio.fmt_int_nl(res['snapshot_interval'])})")
    L.append(f"- init: `{res['init']}` - delingsmechanisme: {res['delingsmechanisme']}")
    L.append(f"- celwaarnemingen: {res['cel_waarnemingen']}, celsporen: {res['sporen']} (+{res['fragmenten']} fragmenten)")
    if res["validatie"]:
        v = res["validatie"]
        L.append(f"- engine-validatie uit stats.csv: T_kin gemiddeld {v.get('T_kin_gemiddeld')} "
                 f"(min/max {v.get('T_kin_min_max')}), langste binding {v.get('max_binding')}")
    L.append(f"\n**Resultaat: {res['n_ja']} van 6 criteria aangetoond.**\n")
    L.append("| # | Criterium | Status | Bewijs | Stappen |")
    L.append("|---|-----------|--------|--------|---------|")
    icon = {"ja": "JA", "deels": "DEELS", "nee": "NEE"}
    for c in res["criteria"]:
        stp = ", ".join(ocio.fmt_int_nl(s) for s in c.get("stappen", [])[:6])
        L.append(f"| {c['id']} | {c['naam']} | **{icon.get(c['status'], c['status'])}** | {c['samenvatting']} | {stp} |")
    if res["kanttekeningen"]:
        L.append("\n## Kanttekeningen\n")
        for k in res["kanttekeningen"]:
            L.append(f"- {k}")
    L.append("\n## Details per criterium\n")
    import json
    for c in res["criteria"]:
        L.append(f"### {c['id']}. {c['naam']} - {c['status']}\n")
        L.append(c["samenvatting"] + "\n")
        L.append("```json")
        L.append(json.dumps(c["bewijs"], indent=1, ensure_ascii=False, default=_np)[:6000])
        L.append("```\n")
    L.append("Methode: zie tools/README.md (celdetectie, tracking, drempels).\n")
    return "\n".join(L)
