#!/usr/bin/env python3
"""Generates app/rpcs3/Settings/settings_layout.json: how RPCS3's desktop settings dialog presents the
settings (tabs, groups, labels and descriptions), read from the Qt frontend, which iOS does not build:

  rpcs3qt/settings_dialog.ui    tabs, group boxes, widget texts
  rpcs3qt/settings_dialog.cpp   which widget edits which setting, and its description
  rpcs3qt/emu_settings_type.cpp which config entry each setting is
  rpcs3qt/tooltips.h            the descriptions
  Emu/system_config.h           the config entries' names in config.yml

The app shows the settings with this layout; values, choices and ranges come from the core at run
time. Run it again when upstream changes the dialog.

  scripts/gen-settings-layout.py
"""

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parent.parent
src = root / "rpcs3" / "rpcs3"
qt = src / "rpcs3qt"
target = root / "app" / "rpcs3" / "Settings" / "settings_layout.json"

STRING = r'"(?:[^"\\]|\\.)*"'


def c_string(literals):
    """The value of adjacent C string literals."""
    text = "".join(lit[1:-1] for lit in re.findall(STRING, literals))
    return bytes(text, "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")


# config.yml names of system_config.h's members: struct -> {member: (name, struct or None)}
def config_names():
    text = (src / "Emu" / "system_config.h").read_text(encoding="utf-8")
    structs, stack, depth = {}, [], 0
    for line in text.splitlines():
        code = line.split("//")[0]
        match = re.match(r"\s*struct (\w+)\s*:\s*cfg::node", code)
        if match:
            stack.append((match.group(1), depth))
            structs[match.group(1)] = {"name": None, "members": {}}
        if stack:
            current = structs[stack[-1][0]]
            ctor = re.search(r"cfg::node\(_this, (" + STRING + ")", code)
            if ctor:
                current["name"] = c_string(ctor.group(1))
            node = re.match(r"\s*(\w+) (\w+)\{\s*this\s*\};", code)
            if node and node.group(1) in structs:
                current["members"][node.group(2)] = (None, node.group(1))
            entry = re.search(r"\b(\w+)\s*\{\s*this\s*,\s*(" + STRING + ")", code)
            if entry:
                current["members"][entry.group(1)] = (c_string(entry.group(2)), None)
        depth += code.count("{") - code.count("}")
        while stack and "}" in code and depth <= stack[-1][1]:
            # A node struct is declared and used at once: "} core{ this };"
            closed = stack.pop()[0]
            member = re.match(r"\s*\}\s*(\w+)\s*\{\s*this\s*\}", code)
            if member and stack:
                structs[stack[-1][0]]["members"][member.group(1)] = (None, closed)
    return structs


def resolve(structs, members):
    """local_cfg.video.vk.adapter -> ["Video", "Vulkan", "Adapter"]"""
    current, path = structs["cfg_root"], []
    for member in members:
        if member not in current["members"]:
            return None
        name, struct = current["members"][member]
        if struct:
            current = structs[struct]
            path.append(current["name"])
        else:
            path.append(name)
    return path


def setting_paths(structs):
    text = (qt / "emu_settings_type.cpp").read_text(encoding="utf-8")
    paths = {}
    for kind, members in re.findall(r"emu_settings_type::(\w+),\s*get_cfg_location\(local_cfg\.([\w.]+)\)", text):
        path = resolve(structs, members.split("."))
        if path:
            paths[kind] = path
    return paths


def tooltips():
    text = (qt / "tooltips.h").read_text(encoding="utf-8")
    return {name: c_string(body) for name, body in
            re.findall(r"const QString (\w+)\s*=\s*tr\(((?:\s*" + STRING + r")+)", text)}


def dialog_bindings(descriptions):
    """setting kind -> widgets, and widget -> description, from settings_dialog.cpp"""
    text = (qt / "settings_dialog.cpp").read_text(encoding="utf-8")
    text = re.sub(r"//[^\n]*", "", text)
    groups = {}  # QButtonGroup variable -> its buttons
    for group, widget in re.findall(r"(\w+)->addButton\(ui->(\w+)", text):
        groups.setdefault(group, []).append(widget)
    widgets_of, description_of = {}, {}
    for statement in text.split(";"):
        kinds = re.findall(r"emu_settings_type::(\w+)", statement)
        widgets = re.findall(r"ui->(\w+)", statement)
        tips = re.findall(r"tooltips\.settings\.(\w+)", statement)
        if len(set(kinds)) == 1 and "GetSetting" not in statement and "SetSetting" not in statement:
            found = list(widgets)
            for group in re.findall(r"EnhanceRadioButton\((\w+)", statement):
                found += groups.get(group, [])
            if found:
                widgets_of.setdefault(kinds[0], [])
                widgets_of[kinds[0]] += [w for w in found if w not in widgets_of[kinds[0]]]
            if tips and kinds[0] not in description_of and tips[0] in descriptions:
                description_of[kinds[0]] = descriptions[tips[0]]
        if tips and widgets and tips[0] in descriptions:
            for widget in widgets:
                description_of.setdefault(widget, descriptions[tips[0]])
    return widgets_of, description_of


def dialog_places():
    """widget -> (tab, group box title, own text, position) from settings_dialog.ui"""
    tree = ET.parse(qt / "settings_dialog.ui").getroot()
    places, order = {}, [0]

    def text_of(widget, prop):
        node = widget.find(f"property[@name='{prop}']/string")
        return node.text if node is not None else None

    def walk(element, tab, group):
        for child in element:
            if child.tag == "widget":
                cls, name = child.get("class"), child.get("name")
                child_tab, child_group = tab, group
                title = child.find("attribute[@name='title']/string")
                if title is not None and element.tag == "widget" and element.get("class") == "QTabWidget":
                    child_tab = title.text
                if cls == "QGroupBox" and text_of(child, "title"):
                    child_group = (name, text_of(child, "title"))
                order[0] += 1
                places[name] = (child_tab, child_group, text_of(child, "text"), order[0])
                walk(child, child_tab, child_group)
            else:
                walk(child, tab, group)

    walk(tree, None, None)
    return places


def main():
    structs = config_names()
    paths = setting_paths(structs)
    descriptions = tooltips()
    widgets_of, description_of = dialog_bindings(descriptions)
    places = dialog_places()

    tabs = {}
    for kind, widgets in widgets_of.items():
        if kind not in paths:
            continue
        placed = [places[w] for w in widgets if w in places and places[w][0]]
        if not placed:
            continue
        tab, group, text, position = min(placed, key=lambda place: place[3])
        group_name = group[1] if group else ""
        own_texts = [places[w][2] for w in widgets if w in places and places[w][2]]
        # A checkbox has its own text; a combo box, radio set or slider is named by its group box
        is_choice = len(own_texts) > 1
        label = own_texts[0] if own_texts and not is_choice else (group_name or paths[kind][-1])
        # Sliders show their value as their text ("100%", "Cache size: 3072 MB"): not a name
        if ":" in label:
            label = label.split(":")[0].strip()
        if re.fullmatch(r"[-\d.,]+\s*\S{0,3}", label):
            label = group_name or paths[kind][-1]
        description = description_of.get(kind) or next(
            (description_of[w] for w in widgets if w in description_of), None) or (
            description_of.get(group[0]) if group else None) or ""
        tabs.setdefault(tab, {}).setdefault(group_name, []).append(
            {"path": paths[kind], "label": label.replace("&&", "&"), "description": description, "position": position})

    tab_order = [place[0] for place in sorted(places.values(), key=lambda p: p[3]) if place[0]]
    layout = []
    for tab in dict.fromkeys(tab_order):
        if tab not in tabs:
            continue
        groups = sorted(tabs[tab].items(), key=lambda g: min(item["position"] for item in g[1]))
        layout.append({"title": tab, "groups": [
            {"title": title, "items": [{k: v for k, v in item.items() if k != "position"}
                                       for item in sorted(items, key=lambda i: i["position"])]}
            for title, items in groups]})

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps({"tabs": layout}, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    count = sum(len(g["items"]) for t in layout for g in t["groups"])
    print(f"{count} settings in {len(layout)} tabs -> {target}")
    missing = sorted(set(widgets_of) - set(paths))
    if missing:
        print(f"  not in the config tree (frontend-only or another file): {', '.join(missing)}", file=sys.stderr)


main()
