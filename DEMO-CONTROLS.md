# Demo Controls

This repo carries a small system for running **live coding demos from git tags**. Each stage of the demo is a commit tagged `step-NN-slug`, and a pair of scripts (plus VS Code status-bar buttons) step forward and back through those tags while you teach.

The point is that you never type git commands in front of a class, never lose your place, and can recover from any mistake by jumping to the next checkpoint.

This file is the operator guide: how the system works, how to author a demo, how to drive it live, and what will bite you. It is written to be copied verbatim into other example repos.

## The pieces

| File | What it does |
|:--|:--|
| `demo.sh` | The navigation script (macOS/Linux) |
| `demo.ps1` | The same thing for Windows PowerShell |
| `.vscode/tasks.json` | Wraps each script command as a VS Code task |
| `.vscode/settings.json` | Turns those tasks into status-bar buttons |
| `.vscode/extensions.json` | Recommends the extension that draws the buttons |
| `demo.conf` | Optional per-project settings, see "Refreshing the app" below |
| `DEMO-CONTROLS.md` | This file |

**The rule that matters most: every one of these files must exist in the first tagged commit.** Checking out a tag deletes tracked files that are not in that tag, so if the tooling was added later than `step-01`, stepping back to step 01 deletes your own controls mid-lecture and the buttons stop working. Add the tooling first, tag afterwards.

Note that `.gitignore` deliberately leaves `.vscode/` tracked (the stock Flutter ignore line for it is commented out). Keep it that way, or the buttons will not travel with the repo.

## One-time setup

- **macOS/Linux:** `chmod +x demo.sh` if you get "Permission denied".
- **Windows:** if scripts are blocked, run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` in PowerShell.
- **VS Code:** install [Task Buttons](https://marketplace.visualstudio.com/items?itemName=spencerwmiles.vscode-task-buttons) (`spencerwmiles.vscode-task-buttons`). `.vscode/extensions.json` will prompt you on first open. Reload the window after installing so the buttons appear.

## Authoring a demo

1. **Work on `main`, never on a tag.** Navigation commands run `git reset --hard` and `git clean -fd`, so any uncommitted work is destroyed the moment you press a step button. Author each stage as a normal commit on `main`.
2. **Write the code for one teaching step**, small enough to narrate.
3. **Run `add-step`** to commit and tag it in one go:

   ```sh
   ./demo.sh add-step model "Add the KaiEvent model"
   ```

   That stages everything (`git add -A` from the repo root), commits with your message, and creates the tag `step-02-model`, working out the number for you as the highest existing step number plus one, zero padded. On Windows: `.\demo.ps1 add-step model "Add the KaiEvent model"`. In VS Code it is the `➕ Demo: Add step` task, which prompts for the slug and the message (Command Palette, "Tasks: Run Task").

   It refuses, without changing anything, if the slug is not lowercase letters, digits and hyphens; if the working tree is clean; if the tag already exists; or if you are on a detached HEAD, which is where the step buttons leave you and where a commit would be lost.
4. **Repeat for each step**, then leave `main` at the final step so a plain clone shows the finished app.
5. **Write the step table into `README.md`** so students can see what each step covers and jump straight to it. The WDCC React workshop README is the reference format: a table of step number, tag name, new concepts, and description.

Nothing in the scripts is language specific, so the same layout works for a Flutter, React, or Node example.

### Changing something in every step

Some files should be identical at every checkpoint: the README, this file, the scripts themselves, a licence. Editing one on `main` is not enough, because checking out `step-03` restores that commit's copy. `update-all` handles it:

```sh
./demo.sh update-all "Add the step table to the README"
```

It commits whatever is in your working tree, rebuilds that commit onto the one *before* step 1, and replays every step on top, so all of them end up carrying it. The step tags are moved to the rewritten commits; their names, order, and their own code are untouched.

It refuses, leaving everything alone, if you give it no message, if the tree is clean, if you are on a detached HEAD, if a step tag is not on the current branch, or if step 1 is the very first commit in the repo (there is nothing to build on). It also checks that the steps came back in the right order before it moves a single tag.

**It rewrites history**, which is fine here: these repos are local teaching artefacts with no shared clones. Before rewriting, it points a `demo-backup` tag at the previous state, so `git reset --hard demo-backup` gets your branch back (you would then have to re-point the step tags yourself).

Use it for files that are the same at every step. If the change touches a file the steps themselves change, such as `lib/main.dart`, the replay will conflict; the command stops, restores everything, and tells you. That is the right answer, because "this line, in every step" is not a well defined thing to ask for when every step has a different version of the file.

`update-all` is macOS and Linux only. On Windows, do it by hand (this is what the command runs):

```sh
git add -A && git commit -m "Your message"
git checkout -B tmp <commit before step 1>
git checkout main -- <the files you changed>
git commit -m "Your message"
git rebase --onto tmp <commit before step 1> <the commit before you committed>
git checkout -B main
# then move each step tag onto the replayed commits, in order:
git tag -f step-01-... <sha>
```

### The tag convention, and doing it by hand

`add-step` exists so you do not have to think about this, but the rules it enforces are worth knowing:

- Tags are `step-NN-slug`, **zero padded to two digits**: `step-01-counter`, `step-02-model`. The scripts only discover tags matching `step-*`, and the VS Code jump prompt defaults to `01`, so the padding is not optional.
- **One tag per commit.** The "you are here" marker comes from `git describe --tags --exact-match`, so two step tags on one commit makes the current step ambiguous.
- **The tooling must be in the first tagged commit** (see the rule above).
- The slug is free text for humans reading `git tag -l`. It plays no part in navigation.

Numbering from the maximum rather than the count means a gap is harmless: if you delete a step from the middle, the next `add-step` still carries on from the highest number and never reuses one.

Doing it by hand is three commands, and is what `add-step` runs for you:

```sh
git add -A
git commit -m "Add the KaiEvent model"
git tag step-02-model
```

## Driving a demo live

Buttons appear in the VS Code status bar. Each one maps to a script command:

| Button | Command | What it does |
|:--|:--|:--|
| `< Prev step` | `./demo.sh prev` | Back one step |
| `> Next step` | `./demo.sh next` | Forward one step |
| `List steps` | `./demo.sh list` | Numbered list of steps, current one marked |
| `Jump` | `./demo.sh jump NN` | Prompts for a step number and goes there |
| `Step 1` | `./demo.sh jump 01` | Back to the start of the demo |
| `main` | `./demo.sh reset` | Leave the demo, return to the `main` branch |

There is also `./demo.sh discard-changes`, which throws away whatever you typed during the lecture without moving steps. Useful when a live experiment goes sideways and you want the current step back exactly as prepared.

`add-step` and `update-all` are authoring commands, not live ones. They are deliberately **not** on the status bar, so there is no button to hit by accident mid-lecture: run them from the terminal or the Command Palette while preparing.

On Windows the same commands are `.\demo.ps1 next`, `.\demo.ps1 jump 02`, and so on.

### Refreshing the app when the step changes

Stepping changes the files on disk, which is not the same thing as the running app noticing. What happens next depends on your stack, and for most of them the answer is "nothing to do":

- **Dev servers that watch the filesystem** (Vite, Next, CRA, `nodemon`, `dotnet watch`) see the checkout themselves and hot reload. The demo scripts stay out of the way entirely.
- **Flutter does not watch files.** `flutter run` reloads when you press `r`, and VS Code's Dart extension reloads on the editor's *save* event, which a `git checkout` never fires. This is why the app used to sit there looking like the previous step until you hit the reload button.

So the scripts handle Flutter themselves. After every `next`, `prev`, `jump`, `reset` and `discard-changes`, `demo.sh` sends the running app a signal: `SIGUSR1` for a hot reload, which is the documented hook in `flutter run --help`. It finds the app from the pid file written by `./demo.sh run`, and failing that by looking for a `flutter run` you started in a terminal yourself. Sessions started by an IDE debugger are deliberately skipped, for the reason below.

```sh
./demo.sh run             # start the app (adds --pid-file for you)
./demo.sh run -d chrome   # extra arguments pass straight through
./demo.sh reload          # refresh by hand, if a reload ever does not take
./demo.sh restart         # hot restart by hand
```

None of this is required. With no app running, navigation prints one quiet line and carries on.

**If you start the app with the IDE's debugger instead** (VS Code's "Start Debugging", or the Run button), the scripts deliberately leave it alone and say so. An IDE runs `flutter run --machine`, which takes a different path through the Flutter tool and never installs the reload signal handlers, so the signal would **kill** the app rather than reload it.

That does not mean you have to give up automatic reloads. **`.vscode/settings.json` in this repo turns them on for debugger sessions**, with two settings:

```json
"dart.previewHotReloadOnSaveWatcher": true,
"dart.flutterHotReloadOnSave": "all"
```

The first is the one that matters. The Dart extension normally hot reloads on the editor's *save* event, which a `git checkout` never fires; this switches it to a filesystem watcher over `**/*.dart`, which does see the checkout. It is marked preview, so if a future extension version drops it, fall back to the keybinding below. Two things it will not do: reload while the analyzer reports errors in the changed file, and notice a step that only *deletes* Dart files, since the watcher listens for changes and creations.

With that setting on, the split is clean and nothing double-reloads: a debugger session is refreshed by the extension, and a `./demo.sh run` session is refreshed by the signal, because the extension only reloads apps it is debugging.

Two alternatives, if you would rather not rely on a preview setting:

- Start the app with `./demo.sh run` instead. Simplest, but you lose the debugger, so no breakpoints.
- Keep the debugger and let the editor do the reload, by binding both to one key. This works on every platform including Windows. In your **user** `keybindings.json` (Command Palette, "Preferences: Open Keyboard Shortcuts (JSON)"):

```json
{
  "key": "cmd+alt+right",
  "command": "runCommands",
  "args": { "commands": [
    { "command": "workbench.action.tasks.runTask", "args": "▶️ Demo: Next Step" },
    { "command": "flutter.hotReload" }
  ]}
},
{
  "key": "cmd+alt+left",
  "command": "runCommands",
  "args": { "commands": [
    { "command": "workbench.action.tasks.runTask", "args": "◀️ Demo: Previous Step" },
    { "command": "flutter.hotReload" }
  ]}
}
```

The `args` string has to match the task label in `.vscode/tasks.json` exactly, emoji included. Use `ctrl+alt+...` on Windows and Linux.

**To hot restart instead of hot reload** on every step change, set `DEMO_RELOAD_SIGNAL="USR2"` in `demo.conf`. Restart is slower and resets the app's state, but it is immune to the cases hot reload cannot handle, such as a step that changes a widget from stateful to stateless.

**`demo.conf`** is optional, lives in the repo root, and is the whole configuration surface:

```sh
DEMO_RUN_CMD="npm run dev"                          # what './demo.sh run' starts
DEMO_AFTER_STEP="curl -s localhost:35729/reload"    # how to refresh, if it needs saying
DEMO_RELOAD_SIGNAL="USR1"                           # Flutter: USR1 reload, USR2 restart
DEMO_MAIN_BRANCH="solution"                         # where 'reset' goes, default main
```

`DEMO_AFTER_STEP` overrides everything else, so any project that needs a different nudge can have one without touching the scripts. A Flutter project needs no `demo.conf` at all.

**Windows has no `SIGUSR1`**, so `demo.ps1` can only remind you to press `R`. The keybinding above is the way to automate it there, and it does not care how the app was started.

**Stepping fast is handled, but not instantly.** Flutter ignores a reload signal that arrives while an earlier reload is still running, so a quick double step would leave the app a step behind. The scripts send a second signal two seconds later to cover that, which means a burst of steps settles on the right screen a beat after you stop clicking. `./demo.sh reload` forces it immediately.

**You will be on a detached HEAD for the whole demo.** That is normal and expected: a tag is not a branch. Nothing you type while detached is worth keeping, and the `main` button gets you home. If you do want to keep an accident, commit it to a new branch before pressing anything else.

**Flutter specifics.** Leave the app alive for the whole lecture; the scripts refresh it for you (see "Refreshing the app" above). If a step ever renders stale, press `R` (capital, hot restart) rather than `r`: a checkout can swap widget types and change state classes, which hot reload will not always survive. Step switching is fast because `git clean -fd` has no `-x`, so ignored build output in `.dart_tool/` and `build/` is left alone and nothing has to be rebuilt.

## Optional: keyboard shortcuts

If you would rather not aim at the status bar mid-sentence, bind the tasks to keys in your **user** `keybindings.json` (Command Palette, "Preferences: Open Keyboard Shortcuts (JSON)"):

```json
{
  "key": "cmd+alt+right",
  "command": "workbench.action.tasks.runTask",
  "args": "▶️ Demo: Next Step"
},
{
  "key": "cmd+alt+left",
  "command": "workbench.action.tasks.runTask",
  "args": "◀️ Demo: Previous Step"
}
```

The `args` string has to match the task label in `.vscode/tasks.json` exactly, emoji included. Keybindings are per user, not per workspace, so they cannot be shipped inside the repo: set them up once on the machine you present from.

## Gotchas

- **Navigation is destructive by design.** `next`, `prev`, `jump` and `reset` all discard uncommitted work first. That is what makes them reliable in front of a class, and it is also how you lose an unsaved idea. Commit before you experiment.
- **`jump` matches the number exactly as tagged.** With a tag named `step-01-counter`, `jump 01` works and `jump 1` reports "Step 1 not found".
- **No `step-*` tags means the scripts refuse to run** and point you back here. This is the expected state of a fresh example repo before its demo has been authored.
- **Ignored files survive, other untracked files do not.** `build/` and `.dart_tool/` stay; a scratch file you created in the project root during the lecture is deleted.
- **`next` from an untagged commit** (for example from `main` after further work) starts the demo at step 01. `prev` from an untagged commit refuses and tells you to run `list`.
- **The step number shown by `list` is a position, not the tag number.** They agree as long as your tags are numbered contiguously from 01.
- **`add-step` refuses on a detached HEAD.** That is the point: you land there after every step button, and a commit made there would be destroyed by the next step change. Run `reset` first. Your uncommitted work is left alone by the refusal, but `reset` will discard it, so move it somewhere safe first if it matters.

## Copying this system into a new example repo

1. Copy `demo.sh`, `demo.ps1`, `.vscode/` and this file into the new project.
2. Trim `.vscode/extensions.json` to the extensions that project actually needs (`Dart-Code.flutter` is the only Flutter specific line).
3. `chmod +x demo.sh`.
4. Decide how the app gets refreshed. If the project's dev server watches files, which most do, there is nothing to do: the Flutter adapter in the scripts checks for a `pubspec.yaml` first and stays dormant without one. Otherwise add a `demo.conf` with `DEMO_RUN_CMD` and, if needed, `DEMO_AFTER_STEP`. Add `.demo-app.pid` to `.gitignore` if you use `demo.sh run`.
5. Commit all of it **before** the first `step-01` tag.
6. Author the steps, tag them, and fill in the step table in that repo's `README.md`.

## Starter and solution repos

A lab repo is shaped differently from a lecture demo. `main` holds the starter code students clone, and the model solution lives on a `solution` branch with one tagged step per task. The demo tooling belongs **only** on `solution`, so that students who clone the starter never see the answers or the scripts.

Two things follow from that:

- **The tooling still has to be in the first tagged commit**, which on this layout is the first commit of the `solution` branch. The rule does not change, only which branch it applies to.
- **`reset` must not go to `main`.** `main` does not have `demo.sh`, `.vscode/` or this file in it, so checking it out would delete your own controls from the working tree. Set `DEMO_MAIN_BRANCH="solution"` in `demo.conf`, and relabel the `🏁 Demo: Back to main` task and its status-bar button so they say what they now do.

`Lab-Activities/lab_01_extending_kai_finder` is the worked example of this layout.

## Student-facing text for the repo README

Paste something like this into `README.md` so students can navigate the steps themselves:

> ### How to use the demo scripts
>
> This project uses git tags to organise the steps we build in class. Navigate them with the provided scripts:
>
> ```sh
> ./demo.sh run             # Start the app
> ./demo.sh list            # Show all available steps
> ./demo.sh next            # Move to the next step
> ./demo.sh prev            # Move to the previous step
> ./demo.sh jump 05         # Jump to a specific step
> ./demo.sh discard-changes # Throw away your changes, stay on this step
> ./demo.sh reset           # Leave the demo, return to the main branch
> ```
>
> On Windows use `.\demo.ps1` instead of `./demo.sh`. If you get "Permission denied" on macOS or Linux, run `chmod +x demo.sh` first. If PowerShell blocks the script, run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`.
>
> Moving between steps **discards any changes you have made**. That is intentional: every step is a clean starting point. If the scripts will not run at all, you can do the same thing by hand:
>
> ```sh
> git reset --hard HEAD
> git clean -fd
> git checkout step-05-something
> ```
