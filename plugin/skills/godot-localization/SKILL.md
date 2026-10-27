---
name: godot-localization
description: Translate a Godot 4 game into other languages with the gd command line - a CSV of translation keys imported into .translation files, registering them in the project settings, tr() and tr_n() in scripts, Labels and Buttons that translate their text by themselves, switching and remembering the language, fonts that have the glyphs (Chinese, Japanese, Korean, Cyrillic), testing a locale and pseudolocalization. Use when the user wants the game in more than one language, mentions translation, localization, i18n, locale, a language menu, or text that should change with the language.
---

# Localization

A translated game keeps its text in a table of keys, one column per language. Godot imports the table into one
`.translation` resource per language; the project lists those resources, and every `tr("KEY")` and every Label or
Button whose text is a key shows the text of the current language. Commands are run with `gd command ...` (see the
`godot-cli` skill).

## The table

A CSV, UTF-8 without a byte order mark. The first column holds the keys, the first row the locale codes; the
top-left cell is ignored (write `keys`). A column whose header starts with `_` is a comment column.

```csv
keys,en,zh,ja
TITLE,My Game,我的游戏,マイゲーム
MENU_PLAY,Play,开始,プレイ
COINS,"Coins: {n}","金币：{n}","コイン：{n}"
```

- Keys are case-sensitive and unique; upper case is the convention. A key that is missing from a column falls back.
- A field with a comma, a line break or a double quote goes in double quotes; a quote inside is doubled (`""`).
- Locale codes are a language (`en`, `zh`, `ja`, `es`) or language and region (`en_GB`, `zh_TW`, `pt_BR`).
  A game usually needs only the language.
- Write it like any text file, then import it:

```bash
gd command fs_write_text --path res://i18n/text.csv --text-file /tmp/text.csv
gd command fs_scan
gd command fs_list --path res://i18n
```

The import makes `text.en.translation`, `text.zh.translation`, ... next to the CSV (the CSV's name, the locale,
`.translation`). The CSV stays the source: edit it and scan again; never edit the `.translation` files.

## Registering the translations

Imported translations do nothing until the project lists them:

```bash
gd command project_settings_set --name internationalization/locale/translations \
  --value '["res://i18n/text.en.translation", "res://i18n/text.zh.translation", "res://i18n/text.ja.translation"]' --yes
gd command project_settings_set --name internationalization/locale/fallback --value '"en"' --yes
```

The list replaces the old one: read it first (`project_settings_get`) when other translations are there. The
fallback is used for a language the game does not have; it defaults to `en`.

## Text that translates

- **Labels, Buttons and other Controls** show the translation when their `text` is a key: set
  `"text": "MENU_PLAY"`. Text that must not be looked up (a player's name, a score) goes on a node with
  `auto_translate_mode` set to disabled (`2`), or would be translated if it happens to match a key.
- **In scripts**: `tr("TITLE")`. Values go in named placeholders, so translators can move them:
  `tr("COINS").format({"n": coins})`. `%s`/`%d` work but fix the order.
- **Plurals**: `tr_n("ONE_COIN", "MANY_COINS", count)`; never `if count > 1` (other languages have more than two
  forms). Plural forms need a CSV with a `?plural` column (Godot 4.6+) or gettext `.po` files; before 4.6 a CSV
  gives `tr_n` the singular every time, so on 4.5 and older use `.po` files for text with a count.
- **The same word with two meanings**: `tr("Close", "Actions")` (a context); in a CSV, a `?context` column (4.6+).
- **A Label set from code** is translated when its text is a key; text built from translated pieces is not looked
  up again.
- **The game's name** per language: the project setting `application/config/name_localized`, a dictionary of
  locale to name.

## Switching the language

```gdscript
TranslationServer.set_locale("zh")          # every tr() and auto-translated Control follows
var current := TranslationServer.get_locale()
var preferred := OS.get_locale_language()   # the player's system language, a good default
```

Save the player's choice in `user://` (a `ConfigFile`) and set it again at start. Controls update by themselves when
the locale changes; text a script set with `tr()` is not set again by itself: listen for
`NOTIFICATION_TRANSLATION_CHANGED` in `_notification` and set it there.

## Fonts

The default font covers few scripts. On desktop the missing glyphs (Chinese, Japanese, Korean, Arabic, ...) come from
a system font, so the editor shows them while a web export or another machine shows boxes: ship a font that has them. The user has to provide the font file (for example a Noto font); then give it to the
theme or to the Controls (see the `godot-ui` skill), with other fonts as fallbacks. Languages written without spaces
(Chinese, Japanese, Thai) also need `internationalization/locale/include_text_server_data` true for line breaking in
an exported game (about 4 MB). Arabic and Hebrew mirror the UI by themselves; check the layout.

## Checking it

```bash
gd command project_settings_set --name internationalization/locale/test --value '"zh"' --yes   # force a locale when running
gd run --headless --seconds 3
gd command project_settings_set --name internationalization/locale/test --value '""' --yes      # and clear it again
```

- `locale/test` forces the language for runs and exports; leave it empty afterwards, or the shipped game is stuck in it.
- `internationalization/pseudolocalization/use_pseudolocalization` true makes every string longer and accented: it
  shows text that is not translated (it stays plain), labels that overflow and missing glyphs.
- On a game started with `editor_play`, `game_call --path Main --method tr --arguments '["TITLE"]'` answers with the
  text in the current language. A Label's `text` property (`game_node_get`) is the key it was given, not what it
  shows: what it shows is `game_call --path Main/Title --method atr --arguments '["TITLE"]'`.
- Text wider in another language breaks layouts: Containers, `autowrap_mode` and `text_overrun_behavior` on Labels.
