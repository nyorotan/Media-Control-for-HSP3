# Media Control for HSP3  
with TaskBarEmbedder module


![ ](./img/01.jpg)

このプロジェクトは、Windows のタスクバーに小さなメディア操作ボタンを埋め込んで使うためのサンプルアプリと、同じ仕組みを自作アプリへ組み込むためのモジュールをまとめたものです。

主な狙いは、HSP3 で「昔の DESKBAND のような、タスクバーに常駐する小さなコントローラ」を手軽に作れるようにすることです。

---

## ユーザー向けガイド（使い方）

このアプリは、タスクバーの端に 4 つのボタンを並べて、音楽の再生・停止・前後移動を簡単に操作できるようにしたサンプルです。

ボタンの役割は次のとおりです。

- 1つ目: 前の曲へ
- 2つ目: 再生 / 一時停止
- 3つ目: 停止
- 4つ目: 次の曲へ

また、右クリックで終了メニューが表示されます。

実際には音楽アプリに対してメディアキーを送る仕組みを使っているため、対応アプリによっては、追加の設定が必要になることがあります。

Windows 11 でタスクバーのアイコンが`中央揃え`の場合は、強制的に`左揃え`に変更され、終了と同時に元`中央揃え`に戻されます。

### 1.事前に確認しておくこと

- このアプリはメディアキーを送信するため、対象アプリや OS の設定によってはグローバルメディアキーを有効化しておく必要があります。
- 一部の音楽アプリでは、バックグラウンド制御やグローバルキーの許可が必要です。
- 設定を有効にしていないと、ボタンを押しても反応しない場合があります。
- タスクバーの表示状態やレイアウトが特殊だと機能しない可能性があります。

### 2.「参考実装」タスクバーの縦置き

![ ](./img/02.jpg)

- 縦置きにも対応はしています。（Windows 10 のみ）
- ただしこれは実験的な実装であり、今後の Windows 11 の仕様変更で挙動が変わる可能性があります。
- そのため、縦置きは「参考実装」とします。

### 3.注意点

- タスクバーの位置やサイズは Windows の状態に応じて変わるため、ボタンの見た目や配置が多少変わることがあります
- 特に Windows 11 では、タスクバーのレイアウトやアイコン配置の仕様が変わっているため、埋め込みしたコントロールと既存アイコンが重なる場合があります
- Windows 10 では、通常はアイコンと重なることはほぼありません

---

## 開発者向けガイド（モジュールの組み込み）

### このプロジェクトの基本思想

このプロジェクトには、タスクバーに小さなコントローラを埋め込むためのモジュール `TaskBarEmbedder.as` が含まれています。

これは「往年の DESKBAND」を意識して作られており、

- 古い DESKBAND は、タスクバーへウィンドウを埋め込んで情報表示や簡易コントロールを常駐させていた
- その発想を HSP3 でも手軽に再現できるようにしたい
- 小型の常駐型コントローラを簡単に開発できるようにしたい

という意図があります。

### 基本的な使い方

まず、自分のアプリに `TaskBarEmbedder.as` を読み込みます。

```hsp3
#include "TaskBarEmbedder.as"
onexit *s_exit

GetTaskBarPosition
pos = stat
GetTaskBarPhysicalSize tbW, tbH

if (pos == TASKBAR_POS_LEFT) | (pos == TASKBAR_POS_RIGHT) {
    screen 0, tbW, 400
    EmbedTargetWindowVertical hwnd, tbW, 400
} else {
    screen 0, 400, tbH
    EmbedTargetWindow hwnd, 400, tbH
}

stop

*s_exit
    CleanupTaskBarEmbedding
    end
```

### 典型的な流れ

1. タスクバーの位置を取得する
2. タスクバーの物理サイズを取得する
3. アプリの画面サイズをそれに合わせて決める
4. 横置きか縦置きかを判定する
5. `EmbedTargetWindow` または `EmbedTargetWindowVertical` で埋め込む
6. アプリ終了時に `CleanupTaskBarEmbedding` を必ず呼ぶ

### このモジュールが提供する主な機能

- `GetTaskBarPosition`
- `GetTaskBarPhysicalSize`
- `GetTaskBarPhysicalWidth`
- `GetTaskBarPhysicalHeight`
- `EmbedTargetWindow`
- `EmbedTargetWindowVertical`
- `CleanupTaskBarEmbedding`

これらを使うことで、1 つのアプリを「タスクバーに常駐する部品」として扱いやすくなります。  
詳細は後述の 公開関数・命令一覧（リファレンス） を参照して下さい。

### 組み込み時の注意点

- タスクバーとアプリの親子関係を作るため、終了時の後片付けは必須です。
- `CleanupTaskBarEmbedding` を呼ばないと、設定や親子関係が残ることがあります。
- 実行中にタスクバーのレイアウトが変わると、位置調整が必要になることがあります。
- タスクバーの高さや幅は OS や DPI によって変わるため、実環境でのテストが大切です。

---

## Windows 10 と Windows 11 の差異

### Windows 10

- `ReBarWindow32` を調整して余白を確保する方式を使う
- 通常はアイコンと重なることが少ない
- 比較的安定しやすい

### Windows 11

- タスクバーのレイアウトが変わるため、アイコンと重なる可能性がある
- そのため、モジュール側では `TaskbarAl` の変更などを使って、レイアウトを一時的に調整することがある
- ただし、ユーザー環境や設定によって差が大きく、完全に安定しているとは限らない

---

## このプロジェクトの位置づけ

このプロジェクトは、単なるメディアコントロールのサンプルではなく、次のような用途を意識して作られています。

- HSP3 でタスクバー埋め込みを簡単に実装する
- 小さな常駐ユーティリティを作る
- `DESKBAND` のような感覚を手軽に試す

そのため、UI やレイアウトの安定性は環境依存が強く、特に Windows 11 では「すべての環境で完全に安定する」と断言できるものではありません。

一方で、タスクバー埋め込みのプロトタイプを手軽に作るには十分に有用です。

---

## 公開関数・命令一覧（リファレンス）

以下は、外部から利用する主要な公開関数・命令です。

| 関数 / 命令名 | 形式 | 概要 | 主な戻り値 |
| :--- | :--- | :--- | :--- |
| `EmbedTargetWindow` | `#deffunc` | 指定ウィンドウを横置きタスクバーへ埋め込み | `stat`: コンテナHWND (失敗時0) |
| `EmbedTargetWindowVertical` | `#deffunc` | 指定ウィンドウを縦置きタスクバーへ埋め込み | `stat`: コンテナHWND (失敗時0) |
| `GetTaskBarPhysicalSize` | `#deffunc` | タスクバーの物理幅・高さを変数に取得 | `stat`: 0(成功), -1(失敗) |
| `GetTaskBarSize` | `#deffunc` | `GetTaskBarPhysicalSize` のエイリアス | `stat`: 0(成功), -1(失敗) |
| `GetTaskBarPhysicalWidth()` | `#defcfunc` | タスクバーの物理幅(px)を返す | 幅(px), 失敗時 -1 |
| `GetTaskBarWidth()` | `#defcfunc` | `GetTaskBarPhysicalWidth` のエイリアス | 幅(px), 失敗時 -1 |
| `GetTaskBarPhysicalHeight()` | `#defcfunc` | タスクバーの物理高さ(px)を返す | 高さ(px), 失敗時 -1 |
| `GetTaskBarHeight()` | `#defcfunc` | `GetTaskBarPhysicalHeight` のエイリアス | 高さ(px), 失敗時 -1 |
| `GetTaskBarPosition` | `#deffunc` | タスクバーの配置位置（上下左右）を判定 | `stat`: 0(上), 1(下), 2(左), 3(右) |
| `Check_win11` | `#deffunc` | Windows 11世代のタスクバーかを判定 | `stat`: 1(Win11), 0(Win10以前) |
| `CleanupTaskBarEmbedding` | `#deffunc` | 埋め込み解除・タスクバー設定等の完全復元 | なし |

### 主要関数の使い方

#### `EmbedTargetWindow`
```hsp3
EmbedTargetWindow hwnd, 400, 120
```

- 横置きタスクバー向け
- 第1引数: 対象ウィンドウハンドル
- 第2引数: 埋め込み領域の幅
- 第3引数: 埋め込み領域の高さ

#### `EmbedTargetWindowVertical`
```hsp3
EmbedTargetWindowVertical hwnd, 80, 400
```

- 縦置きタスクバー向け
- 第1引数: 対象ウィンドウハンドル
- 第2引数: 埋め込み領域の幅
- 第3引数: 埋め込み領域の高さ
- これは実験的な実装であり、Windows の今後の仕様変更で動作が変わる可能性がある

#### `GetTaskBarPosition`
```hsp3
GetTaskBarPosition
pos = stat
```

- `TASKBAR_POS_TOP` = 0
- `TASKBAR_POS_BOTTOM` = 1
- `TASKBAR_POS_LEFT` = 2
- `TASKBAR_POS_RIGHT` = 3

#### `GetTaskBarPhysicalSize`
```hsp3
GetTaskBarPhysicalSize tbW, tbH
```

- タスクバーの物理ピクセルサイズを取得する
- DPI を意識した実際の画面サイズを返す

#### `CleanupTaskBarEmbedding`
```hsp3
CleanupTaskBarEmbedding
```

- 終了時や再配置時に必ず呼ぶ
- 監視フックの解除、親子関係の解除、タスクバー設定の復元を行う

---

## ライセンス

本プロジェクトは `NYSL(煮るなり焼くなり好きにしろライセンス)` の下で公開されています。

`煮るなり焼くなり好きにしてください。`

- **著作権**: © 2026 nyorotan

## バージョン情報

- **バージョン**: v1.0.0
- **作者**: nyorotan
