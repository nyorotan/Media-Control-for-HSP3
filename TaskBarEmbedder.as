;==============================================================================
; TaskBarEmbedder.as
; タスクバー埋め込みモジュール (for HSP 3.6以降)
;
; 【概要】
; HSPで作成したウィンドウを、Windowsのタスクバー（通知領域付近）に
; 埋め込んで表示・常駐させるためのモジュールです。
; 横置きタスクバー（上下配置）および縦置きタスクバー（左右配置）に対応しています。
;
; 【特徴】
; - Windows 10 および Windows 11 の両方に対応
;   - Windows 10: ReBarWindow32 をリサイズしてトレイ付近にスペースを確保
;   - Windows 11: タスクバーアイコンの左揃え化を行い、トレイ付近に安全に配置
; - Per-Monitor DPI Aware 対応（マルチモニター・高DPI環境でのズレを防止）
; - タスクバーの物理サイズ（幅・高さ）および配置位置（上下左右）の取得に対応
; - 横置き用 (EmbedTargetWindow) と 縦置き用 (EmbedTargetWindowVertical) を完備
; - アプリ終了時の復元・クリーンアップ処理を完備
;
; 【基本的な使い方】
;   #include "TaskBarEmbedder.as"
;   onexit *s_exit
;
;   // 1. タスクバーの位置・サイズを取得
;   GetTaskBarPosition
;   tbPos = stat
;   tbW = 0 : tbH = 0
;   GetTaskBarPhysicalSize tbW, tbH
;
;   // 2. 向きに合わせてウィンドウ作成・埋め込み
;   if (tbPos == TASKBAR_POS_LEFT) | (tbPos == TASKBAR_POS_RIGHT) {
;       screen 0, tbW, 400
;       button gosub "Click", *btn
;       EmbedTargetWindowVertical hwnd, tbW, 400
;   } else {
;       screen 0, 400, tbH
;       button "Click", *btn
;       EmbedTargetWindow hwnd, 400, tbH
;   }
;   stop
;
; *btn
;   dialog "ボタンが押されました！"
;   return
;
; *s_exit
;   // 3. 終了時に必ずクリーンアップを呼び出す
;   CleanupTaskBarEmbedding
;   end
;==============================================================================
#include "user32.as"
#include "shell32.as"
#include "gdi32.as"
#include "modclbk3.hsp"

#uselib "user32.dll"
	#func global SetProcessDpiAwarenessContext "SetProcessDpiAwarenessContext" int
	#func global SetProcessDPIAware "SetProcessDPIAware"
	#func global GetDpiForWindow "GetDpiForWindow" int
	#func global AdjustWindowRectExForDpi "AdjustWindowRectExForDpi" int, int, int, int, int
    #func global SetThreadDpiAwarenessContext "SetThreadDpiAwarenessContext" int

#uselib "advapi32.dll"
	#func global RegOpenKeyEx "RegOpenKeyExA" int, str, int, int, int
	#func global RegQueryValueEx "RegQueryValueExA" int, str, int, int, int, int
	#func global RegSetValueEx "RegSetValueExA" int, str, int, int, int, int
	#func global RegCloseKey "RegCloseKey" int

;------------------------------------------------------------------------------
; 定数定義 (Windows API / AppBar / Window Style)
;------------------------------------------------------------------------------
// AppBar メッセージ
#define global ABM_GETSTATE                    0x00000004
#define global ABM_GETTASKBARPOS               0x00000005

// ウィンドウメッセージ
#define global WM_CREATE                       0x0001
#define global WM_DESTROY                      0x0002
#define global WM_CLOSE                        0x0010
#define global WM_QUERYENDSESSION              0x0011
#define global WM_SETTINGCHANGE                0x001A

// ウィンドウスタイル
#define global WS_CHILD                        0x40000000
#define global WS_VISIBLE                      0x10000000
#define global WS_CLIPSIBLINGS                 0x04000000
#define global WS_CLIPCHILDREN                 0x02000000
#define global WS_TABSTOP                      0x00010000
#define global WS_GROUP                        0x00020000
#define global WS_SYSMENU                      0x00080000

// 拡張ウィンドウスタイル
#define global WS_EX_CONTROLPARENT             0x00010000
#define global WS_EX_LAYERED                   0x00080000

// Zオーダー
#define global HWND_TOPMOST                    -1

// イベントフック
#define global EVENT_OBJECT_LOCATIONCHANGE     0x800B
#define global WINEVENT_OUTOFCONTEXT           0x0000

// レジストリ関連 (Windows 11 タスクバー設定調整用)
#define global HKEY_CURRENT_USER               0x80000001
#define global KEY_READ                        0x00020019
#define global KEY_WRITE                       0x00020006
#define global SMTO_ABORTIFHUNG                0x0002

// タスクバー配置位置 (GetTaskBarPosition の戻り値)
#define global TASKBAR_POS_TOP                 0   // 画面上部
#define global TASKBAR_POS_BOTTOM              1   // 画面下部
#define global TASKBAR_POS_LEFT                2   // 画面左側
#define global TASKBAR_POS_RIGHT               3   // 画面右側

#module TaskBarEmbedder

	#deffunc _tb_ClearContext
		// 既存の埋め込み状態を消して、次の起動時に古いハンドルやフラグが残らないようにする
		_tb_newfook = 0
		_tb_mhtask = 0
		_tb_targetHwnd = 0
		_tb_hwndrb = 0
		_tb_hwndTaskBar = 0
		_tb_isResizing = 0
		_tb_rbOrigWidth = 0
		_tb_rbOrigHeight = 0
		_tb_rbRelX = 0
		_tb_rbRelY = 0
		_tb_rbTargetWidth = 0
		_tb_rbTargetHeight = 0
		_tb_rectbw_2 = 0
		_tb_rectbw_3 = 0
		_tb_rectn_0 = 0
		_tb_rectn_1 = 0
		_tb_w11 = 0
		_tb_taskbarAlDirty = 0
		_tb_taskbarAlOriginal = -1
		return

	#deffunc _tb_ApplyTaskbarAlLeftAligned
		// Windows 11 では TaskbarAl を一時的に左揃え(0)へ変更するが、元の値を控えておく
		// これにより、終了時に「自分が変えたものだけ」を戻せるようにしている
		_tb_taskbarAlDirty = 0
		_tb_taskbarAlOriginal = -1
		subKeyPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced"
		currentAlign = 1
		RegOpenKeyEx HKEY_CURRENT_USER, subKeyPath, 0, KEY_READ, varptr(lvar_hKey)
		if stat == 0 {
			hKey = lvar_hKey
			size = 4
			RegQueryValueEx hKey, "TaskbarAl", 0, 0, varptr(currentAlign), varptr(size)
			RegCloseKey hKey
		}
		_tb_taskbarAlOriginal = currentAlign
		if _tb_taskbarAlOriginal != 0 {
			RegOpenKeyEx HKEY_CURRENT_USER, subKeyPath, 0, KEY_WRITE, varptr(lvar_hKey)
			if stat == 0 {
				hKey = lvar_hKey
				val = 0
				RegSetValueEx hKey, "TaskbarAl", 0, 4, varptr(val), 4
				RegCloseKey hKey
				mstring = "TraySettings"
				SendMessageTimeout 0xFFFF, WM_SETTINGCHANGE, 0, varptr(mstring), SMTO_ABORTIFHUNG, 5000, res
				_tb_taskbarAlDirty = 1
			}
			wait 50
		}
		return

	#deffunc _tb_RestoreTaskbarAlIfNeeded
		// 変更していない場合は戻さない
		// これで「元の設定を壊したまま放置する」事故を防ぐ
		if _tb_taskbarAlDirty == 0 { return }
		if _tb_taskbarAlOriginal < 0 { return }
		subKeyPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced"
		RegOpenKeyEx HKEY_CURRENT_USER, subKeyPath, 0, KEY_WRITE, varptr(lvar_hKey)
		if stat == 0 {
			hKey = lvar_hKey
			val = _tb_taskbarAlOriginal
			RegSetValueEx hKey, "TaskbarAl", 0, 4, varptr(val), 4
			RegCloseKey hKey
			mstring = "TraySettings"
			SendMessageTimeout 0xFFFF, WM_SETTINGCHANGE, 0, varptr(mstring), SMTO_ABORTIFHUNG, 5000, res
		}
		_tb_taskbarAlDirty = 0
		_tb_taskbarAlOriginal = -1
		return

	//==========================================================================
	// EmbedTargetWindow
	//
	// 指定したウィンドウハンドル(targetHwnd)を横置きタスクバーに埋め込みます。
	// 親コンテナウィンドウも横置き（通知領域の左側）に配置されます。
	//
	// [引数]
	//   targetHwnd : 埋め込み対象のウィンドウハンドル (通常は hwnd)
	//   pWidth     : 埋め込み領域の幅 (ピクセル)
	//   pHeight    : 埋め込み領域の高さ (ピクセル)
	//
	// [戻り値]
	//   stat       : 作成されたコンテナウィンドウのハンドル (失敗時は 0)
	//
	// [説明]
	//   - Windows 11 の場合は自動的にタスクバーを「左揃え」に変更してスペースを確保します。
	//   - Windows 10 の場合は ReBarWindow32 をリサイズして通知領域(Tray)の左にスペースを空けます。
	//   - 親コンテナウィンドウを作成し、targetHwnd をその子として SetParent で収容します。
	//   - アプリ終了時には必ず CleanupTaskBarEmbedding を呼び出してください。
	//==========================================================================
	#deffunc EmbedTargetWindow int targetHwnd, int pWidth, int pHeight
		if _tb_mhtask != 0 | _tb_targetHwnd != 0 | _tb_newfook != 0 {
			CleanupTaskBarEmbedding
		}
		_tb_ClearContext
		_tb_isVertical = 0
		SetProcessDpiAwarenessContext -4
		if stat == 0 : SetProcessDPIAware

		// コールバックプロシージャの登録
		newclbk3 _tb_Proc, 4, *__tb_WndProc
		newclbk3 _tb_Proc2, 7, *__tb_WndProc2

		// デスクトップのハンドル & DPI取得
		GetDesktopWindow
		mhdesktop = stat
		DPI = GetDpiForWindow(mhdesktop)

		// APPBARDATA構造体の初期化
		dim APPBARDATA, 9
		APPBARDATA(0) = 36

		// タスクバーウィンドウの取得とOS判定
		hwndTaskBar = FindWindow("Shell_TrayWnd", "")
		Check_win11 hwndTaskBar
		_tb_w11 = stat

		// Windows 11の場合、元の TaskbarAl を保存し、必要時のみ左揃え(0)に変更する
		if _tb_w11 > 0 {
			_tb_ApplyTaskbarAlLeftAligned
			if _tb_taskbarAlDirty != 0 {
				hwndTaskBar = FindWindow("Shell_TrayWnd", "")
			}
		}

		// タスクバーの位置・矩形を取得
		SHAppBarMessage ABM_GETSTATE, varptr(APPBARDATA)
		SHAppBarMessage ABM_GETTASKBARPOS, varptr(APPBARDATA)

		dim rectask, 4
		rectask(0) = APPBARDATA(4)
		rectask(1) = APPBARDATA(5)
		rectask(2) = APPBARDATA(6)
		rectask(3) = APPBARDATA(7)

		// 通知領域 "TrayNotifyWnd" の位置を取得
		dim rectn, 4
		FindWindowEx hwndTaskBar, 0, "TrayNotifyWnd", NULL
		hwndtn = stat
		GetWindowRect hwndtn, varptr(rectn)

		// タスクバー内の ReBarWindow32 の位置・幅を取得
		dim recrb, 4
		FindWindowEx hwndTaskBar, 0, "ReBarWindow32", NULL
		_tb_hwndrb = stat
		if _tb_hwndrb != 0 {
			GetWindowRect _tb_hwndrb, varptr(recrb)
			_tb_rbOrigWidth = recrb(2) - recrb(0)
			_tb_rbOrigHeight = recrb(3) - recrb(1)
			_tb_rbRelX = recrb(0) - rectask(0)
			_tb_rbRelY = recrb(1) - rectask(1)
		} else {
			_tb_rbOrigWidth = 0
			_tb_rbOrigHeight = 0
			_tb_rbRelX = 0
			_tb_rbRelY = 0
		}
		_tb_isResizing = 0

		// ウィンドウクラス登録 (targetHwnd をクラス名に含めて一意化)
		_tb_ClassName = "testber_" + targetHwnd
		LoadIcon 0, 32518
		hIcon = stat
		LoadCursor 0, 32518
		hCursor = stat
		GetStockObject 0
		hBrush = stat

		dim wcex, 12
		wcex(0) = 48
		wcex(1) = 0
		wcex(2) = _tb_Proc
		wcex(3) = 0
		wcex(4) = 0
		wcex(5) = 0
		wcex(6) = hIcon
		wcex(7) = hCursor
		wcex(8) = hBrush
		wcex(9) = 0
		wcex(10) = varptr(_tb_ClassName)
		wcex(11) = hIcon

		RegisterClassEx varptr(wcex)

		// DPIに応じたウィンドウサイズの調整
		nWidth = pWidth
		nHeight = pHeight
		dim rectbw, 4
		rectbw(0) = 0
		rectbw(1) = 0
		rectbw(2) = nWidth
		rectbw(3) = nHeight
		AdjustWindowRectExForDpi varptr(rectbw), WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_TABSTOP | WS_CLIPCHILDREN | WS_GROUP | WS_SYSMENU, 0, WS_EX_CONTROLPARENT | WS_EX_LAYERED, DPI

		_tb_rbTargetWidth = _tb_rbOrigWidth - rectbw(2)
		_tb_rectbw_2 = rectbw(2)
		_tb_rectbw_3 = rectbw(3)
		_tb_rectn_0 = rectn(0)
		_tb_hwndTaskBar = hwndTaskBar
		_tb_targetHwnd = targetHwnd

		// 1. タスクバー内に親コンテナウィンドウを作成
		CreateWindowEx WS_EX_CONTROLPARENT | WS_EX_LAYERED, _tb_ClassName, "Title", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_TABSTOP | WS_CLIPCHILDREN | WS_GROUP | WS_SYSMENU, rectbw(0), rectbw(1), rectbw(2), rectbw(3), hwndTaskBar, 0, 0, 0
		_tb_mhtask = stat
		SetLayeredWindowAttributes _tb_mhtask, 0xffffff, 200, 0x2

		// 2. ユーザーのウィンドウ(targetHwnd)をコンテナの子ウィンドウに設定し、サイズを合わせる
		SetParent targetHwnd, _tb_mhtask
		MoveWindow targetHwnd, 0, 0, rectbw(2), rectbw(3), 0x0001

		// イベントフックの登録 (ReBarWindow32の位置変更を監視)
		if _tb_hwndrb != 0 {
			GetWindowThreadProcessId _tb_hwndrb, varptr(pidtbar)
			idtbar = stat
			SetWinEventHook EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, 0, _tb_Proc2, pidtbar, idtbar, WINEVENT_OUTOFCONTEXT
			_tb_newfook = stat
		}
		return _tb_mhtask

	//==========================================================================
	// EmbedTargetWindowVertical
	//
	// 指定したウィンドウハンドル(targetHwnd)を縦置きタスクバーに埋め込みます。
	// 親コンテナウィンドウも縦長になり、通知領域の上側に配置されます。
	//
	// [引数]
	//   targetHwnd : 埋め込み対象のウィンドウハンドル (通常は hwnd)
	//   pWidth     : 埋め込み領域の幅 (ピクセル、通常はタスクバー幅)
	//   pHeight    : 埋め込み領域の高さ (ピクセル)
	//
	// [戻り値]
	//   stat       : 作成されたコンテナウィンドウのハンドル (失敗時は 0)
	//==========================================================================
	#deffunc EmbedTargetWindowVertical int targetHwnd, int pWidth, int pHeight
		if _tb_mhtask != 0 | _tb_targetHwnd != 0 | _tb_newfook != 0 {
			CleanupTaskBarEmbedding
		}
		_tb_ClearContext
		_tb_isVertical = 1
		SetProcessDpiAwarenessContext -4
		if stat == 0 : SetProcessDPIAware

		// コールバックプロシージャの登録
		newclbk3 _tb_Proc, 4, *__tb_WndProc
		newclbk3 _tb_Proc2, 7, *__tb_WndProc2

		// デスクトップのハンドル & DPI取得
		GetDesktopWindow
		mhdesktop = stat
		DPI = GetDpiForWindow(mhdesktop)

		// APPBARDATA構造体の初期化
		dim APPBARDATA, 9
		APPBARDATA(0) = 36

		// タスクバーウィンドウの取得とOS判定
		hwndTaskBar = FindWindow("Shell_TrayWnd", "")
		Check_win11 hwndTaskBar
		_tb_w11 = stat

		// Windows 11の場合、元の TaskbarAl を保存し、必要時のみ左揃え(0)に変更する
		if _tb_w11 > 0 {
			_tb_ApplyTaskbarAlLeftAligned
			if _tb_taskbarAlDirty != 0 {
				hwndTaskBar = FindWindow("Shell_TrayWnd", "")
			}
		}

		// タスクバーの位置・矩形を取得
		SHAppBarMessage ABM_GETSTATE, varptr(APPBARDATA)
		SHAppBarMessage ABM_GETTASKBARPOS, varptr(APPBARDATA)

		dim rectask, 4
		rectask(0) = APPBARDATA(4)
		rectask(1) = APPBARDATA(5)
		rectask(2) = APPBARDATA(6)
		rectask(3) = APPBARDATA(7)

		// 通知領域 "TrayNotifyWnd" の位置を取得
		dim rectn, 4
		FindWindowEx hwndTaskBar, 0, "TrayNotifyWnd", NULL
		hwndtn = stat
		GetWindowRect hwndtn, varptr(rectn)

		// タスクバー内の ReBarWindow32 の位置・サイズを取得
		dim recrb, 4
		FindWindowEx hwndTaskBar, 0, "ReBarWindow32", NULL
		_tb_hwndrb = stat
		if _tb_hwndrb != 0 {
			GetWindowRect _tb_hwndrb, varptr(recrb)
			_tb_rbOrigWidth = recrb(2) - recrb(0)
			_tb_rbOrigHeight = recrb(3) - recrb(1)
			_tb_rbRelX = recrb(0) - rectask(0)
			_tb_rbRelY = recrb(1) - rectask(1)
		} else {
			_tb_rbOrigWidth = 0
			_tb_rbOrigHeight = 0
			_tb_rbRelX = 0
			_tb_rbRelY = 0
		}
		_tb_isResizing = 0

		// ウィンドウクラス登録 (targetHwnd をクラス名に含めて一意化)
		_tb_ClassName = "testber_" + targetHwnd
		LoadIcon 0, 32518
		hIcon = stat
		LoadCursor 0, 32518
		hCursor = stat
		GetStockObject 0
		hBrush = stat

		dim wcex, 12
		wcex(0) = 48
		wcex(1) = 0
		wcex(2) = _tb_Proc
		wcex(3) = 0
		wcex(4) = 0
		wcex(5) = 0
		wcex(6) = hIcon
		wcex(7) = hCursor
		wcex(8) = hBrush
		wcex(9) = 0
		wcex(10) = varptr(_tb_ClassName)
		wcex(11) = hIcon

		RegisterClassEx varptr(wcex)

		// DPIに応じたウィンドウサイズの調整
		nWidth = pWidth
		nHeight = pHeight
		dim rectbw, 4
		rectbw(0) = 0
		rectbw(1) = 0
		rectbw(2) = nWidth
		rectbw(3) = nHeight
		AdjustWindowRectExForDpi varptr(rectbw), WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_TABSTOP | WS_CLIPCHILDREN | WS_GROUP | WS_SYSMENU, 0, WS_EX_CONTROLPARENT | WS_EX_LAYERED, DPI

		// 縦置き時は ReBarWindow32 の高さを縮める
		_tb_rbTargetWidth = _tb_rbOrigWidth
		_tb_rbTargetHeight = _tb_rbOrigHeight - rectbw(3)
		_tb_rectbw_2 = rectbw(2)
		_tb_rectbw_3 = rectbw(3)
		_tb_rectn_0 = rectn(0)
		_tb_rectn_1 = rectn(1)
		_tb_hwndTaskBar = hwndTaskBar
		_tb_targetHwnd = targetHwnd

		// 1. タスクバー内に親コンテナウィンドウを作成
		CreateWindowEx WS_EX_CONTROLPARENT | WS_EX_LAYERED, _tb_ClassName, "Title", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_TABSTOP | WS_CLIPCHILDREN | WS_GROUP | WS_SYSMENU, rectbw(0), rectbw(1), rectbw(2), rectbw(3), hwndTaskBar, 0, 0, 0
		_tb_mhtask = stat
		SetLayeredWindowAttributes _tb_mhtask, 0xffffff, 200, 0x2

		// 2. ユーザーのウィンドウ(targetHwnd)をコンテナの子ウィンドウに設定し、サイズを合わせる
		SetParent targetHwnd, _tb_mhtask
		MoveWindow targetHwnd, 0, 0, rectbw(2), rectbw(3), 0x0001

		// イベントフックの登録 (ReBarWindow32の位置・サイズ変更を監視)
		if _tb_hwndrb != 0 {
			GetWindowThreadProcessId _tb_hwndrb, varptr(pidtbar)
			idtbar = stat
			SetWinEventHook EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, 0, _tb_Proc2, pidtbar, idtbar, WINEVENT_OUTOFCONTEXT
			_tb_newfook = stat
		}
		return _tb_mhtask

	//==========================================================================
	// Check_win11
	//
	// 対象タスクバーが Windows 11 世代かどうかを判定します。
	//
	// [引数]
	//   hwndT : タスクバーのウィンドウハンドル (省略または 0 で自動検索)
	//
	// [戻り値]
	//   stat  : 1=Windows 11以降, 0=Windows 10以前
	//==========================================================================
	#deffunc Check_win11 int hwndT
		targetH = hwndT
		if targetH == 0 : targetH = FindWindow("Shell_TrayWnd", "")
		FindWindowEx targetH, 0, "Windows.UI.Composition.DesktopWindowContentBridge", NULL
		return (stat != 0)

	//==========================================================================
	// GetTaskBarPosition
	//
	// タスクバーの画面上の配置位置（上下左右）を取得します。
	//
	// [戻り値]
	//   stat : 配置位置を示す定数 (失敗時は -1)
	//          TASKBAR_POS_TOP    (0) : 画面上部
	//          TASKBAR_POS_BOTTOM (1) : 画面下部
	//          TASKBAR_POS_LEFT   (2) : 画面左側
	//          TASKBAR_POS_RIGHT  (3) : 画面右側
	//==========================================================================
	#deffunc GetTaskBarPosition
		hwndTB = FindWindow("Shell_TrayWnd", "")
		if hwndTB == 0 : return -1

		dim abd, 9
		abd(0) = 36
		SHAppBarMessage ABM_GETTASKBARPOS, varptr(abd)

		// APPBARDATA構造体の uEdge は offset 12 (4番目のメンバ abd(3))
		// 値: 0=左(ABE_LEFT), 1=上(ABE_TOP), 2=右(ABE_RIGHT), 3=下(ABE_BOTTOM)
		edge = abd(3)
		switch edge
			case 0 // ABE_LEFT
				return TASKBAR_POS_LEFT
			case 1 // ABE_TOP
				return TASKBAR_POS_TOP
			case 2 // ABE_RIGHT
				return TASKBAR_POS_RIGHT
			case 3 // ABE_BOTTOM
				return TASKBAR_POS_BOTTOM
			default
				return TASKBAR_POS_BOTTOM
		swend
		return TASKBAR_POS_BOTTOM

	//==========================================================================
	// GetTaskBarPhysicalSize / GetTaskBarSize
	//
	// タスクバーの物理サイズ（幅と高さ）を取得します。
	// DPI仮想化の影響を受けず、画面の実際のピクセル単位で取得します。
	//
	// [引数]
	//   outWidth  : 幅を受け取る変数 (ピクセル)
	//   outHeight : 高さを受け取る変数 (ピクセル)
	//
	// [戻り値]
	//   stat      : 0=取得成功, -1=取得失敗
	//==========================================================================
	#deffunc GetTaskBarPhysicalSize var outWidth, var outHeight
		SetProcessDpiAwarenessContext -4
		if stat == 0 : SetProcessDPIAware

		hwndTB = FindWindow("Shell_TrayWnd", "")
		if hwndTB == 0 {
			outWidth = 0
			outHeight = 0
			return -1
		}

		dim rcTB, 4
		GetWindowRect hwndTB, varptr(rcTB)
		w = rcTB(2) - rcTB(0)
		h = rcTB(3) - rcTB(1)

		// GetWindowRectで取得できない場合のフォールバック
		if (w <= 0) | (h <= 0) {
			dim abdTB, 9
			abdTB(0) = 36
			SHAppBarMessage ABM_GETTASKBARPOS, varptr(abdTB)
			w = abdTB(6) - abdTB(4)
			h = abdTB(7) - abdTB(5)
		}

		outWidth = w
		outHeight = h
		return 0

	// GetTaskBarPhysicalSize のエイリアス
	#deffunc GetTaskBarSize var outWidth, var outHeight
		GetTaskBarPhysicalSize outWidth, outHeight
		return stat

	//==========================================================================
	// GetTaskBarPhysicalWidth / GetTaskBarWidth
	//
	// タスクバーの物理幅を取得する関数です。
	//
	// [戻り値]
	//   タスクバーの物理幅 (ピクセル)。失敗時は -1。
	//==========================================================================
	#defcfunc GetTaskBarPhysicalWidth
		tbW = 0 : tbH = 0
		GetTaskBarPhysicalSize tbW, tbH
		if stat != 0 : return -1
		return tbW

	// GetTaskBarPhysicalWidth のエイリアス
	#defcfunc GetTaskBarWidth
		return GetTaskBarPhysicalWidth()

	//==========================================================================
	// GetTaskBarPhysicalHeight / GetTaskBarHeight
	//
	// タスクバーの物理高さを取得する関数です。
	// ウィンドウ初期化時 (screen命令など) の高さ指定に便利です。
	//
	// [戻り値]
	//   タスクバーの物理高さ (ピクセル)。失敗時は -1。
	//==========================================================================
	#defcfunc GetTaskBarPhysicalHeight
		tbW = 0 : tbH = 0
		GetTaskBarPhysicalSize tbW, tbH
		if stat != 0 : return -1
		return tbH

	// GetTaskBarPhysicalHeight のエイリアス
	#defcfunc GetTaskBarHeight
		return GetTaskBarPhysicalHeight()

	//==========================================================================
	// CleanupTaskBarEmbedding
	//
	// タスクバー埋め込みのクリーンアップ処理を行います。
	// アプリケーション終了時（onexit 等）に必ず呼び出してください。
	//
	// [説明]
	//   - イベントフックの解除
	//   - Windows 10: ReBarWindow32 の幅・高さの復元
	//   - Windows 11: タスクバーアイコン配置（中央揃えなど）の設定復元
	//   - 親ウィンドウ関係の解除およびコンテナウィンドウの破棄
	//==========================================================================
	#deffunc CleanupTaskBarEmbedding
		// イベントフックの解除
		if _tb_newfook != 0 {
			UnhookWinEvent _tb_newfook
			_tb_newfook = 0
		}

		// Windows 10: ReBarWindow32 を元のサイズに戻す
		if _tb_w11 == 0 {
			FindWindowEx _tb_hwndTaskBar, 0, "ReBarWindow32", NULL
			cur_hwndrb = stat
			if cur_hwndrb != 0 {
				IsWindow cur_hwndrb
				if stat != 0 {
					_tb_isResizing = 1
					MoveWindow cur_hwndrb, _tb_rbRelX, _tb_rbRelY, _tb_rbOrigWidth, _tb_rbOrigHeight, 0x0001
					_tb_isResizing = 0
				}
			} else:if _tb_hwndrb != 0 {
				IsWindow _tb_hwndrb
				if stat != 0 {
					_tb_isResizing = 1
					MoveWindow _tb_hwndrb, _tb_rbRelX, _tb_rbRelY, _tb_rbOrigWidth, _tb_rbOrigHeight, 0x0001
					_tb_isResizing = 0
				}
			}
			mstring = "TraySettings"
			SendMessageTimeout 0xFFFF, WM_SETTINGCHANGE, 0, varptr(mstring), SMTO_ABORTIFHUNG, 5000, res
		} else {
			// Windows 11: 元の値が変更されていた場合だけ戻す
			_tb_RestoreTaskbarAlIfNeeded
		}

		// ターゲットウィンドウの親子関係を解除
		if _tb_targetHwnd != 0 {
			IsWindow _tb_targetHwnd
			if stat != 0 {
				SetParent _tb_targetHwnd, 0
			}
			_tb_targetHwnd = 0
		}

		// コンテナウィンドウの破棄
		if _tb_mhtask != 0 {
			IsWindow _tb_mhtask
			if stat != 0 {
				DestroyWindow _tb_mhtask
			}
			_tb_mhtask = 0
		}
		return

	//--------------------------------------------------------------------------
	// 内部用コールバックプロシージャ (ウィンドウメッセージ処理)
	//--------------------------------------------------------------------------
	*__tb_WndProc
		dim callbkarg, 4
		clbkargprotect callbkarg
		hWindow = callbkarg(0)
		Massage = callbkarg(1)
		wp      = callbkarg(2)
		lp      = callbkarg(3)
		switch Massage
			case WM_CREATE
				SetLayeredWindowAttributes hWindow, 0, 255, 0x00000002
				barvar = 0
				if _tb_w11 > 0 { barvar = 1 }
				switch barvar
					case 0
						// Win10: ReBarWindow32を縮めてスペースを空ける
						if _tb_isVertical != 0 {
							// 縦置き: 通知領域の上側に配置
							y = _tb_rectn_1 - _tb_rectbw_3
							MoveWindow hWindow, 0, y, _tb_rectbw_2, _tb_rectbw_3, 0x0001
							_tb_isResizing = 1
							MoveWindow _tb_hwndrb, _tb_rbRelX, _tb_rbRelY, _tb_rbTargetWidth, _tb_rbTargetHeight, 0x0001
							_tb_isResizing = 0
						} else {
							// 横置き: 通知領域の左側に配置
							x = _tb_rectn_0 - _tb_rectbw_2
							MoveWindow hWindow, x, 0, _tb_rectbw_2, _tb_rectbw_3, 0x0001
							_tb_isResizing = 1
							MoveWindow _tb_hwndrb, _tb_rbRelX, 0, _tb_rbTargetWidth, _tb_rectbw_3, 0x0001
							_tb_isResizing = 0
						}
						SetWindowPos hWindow, HWND_TOPMOST, 0, 0, 0, 0, 3
						swbreak
					case 1
						// Win11:
						if _tb_isVertical != 0 {
							// 縦置き: TrayNotifyWndの上側に配置
							y = _tb_rectn_1 - _tb_rectbw_3
							MoveWindow hWindow, 0, y, _tb_rectbw_2, _tb_rectbw_3, 0x0001
						} else {
							// 横置き: TrayNotifyWndの左側に配置
							x = _tb_rectn_0 - _tb_rectbw_2
							MoveWindow hWindow, x, 0, _tb_rectbw_2, _tb_rectbw_3, 0x0001
						}
						SetWindowPos hWindow, 0, 0, 0, 0, 0, 3
						swbreak
					default
						swbreak
				swend
				return 0

			case WM_CLOSE
				UnhookWinEvent _tb_newfook
				DestroyWindow hWindow
				return 0

			case WM_DESTROY
				UnhookWinEvent _tb_newfook
				return 0

			case WM_QUERYENDSESSION
				CleanupTaskBarEmbedding
				return 1

			default
				DefWindowProc hWindow, Massage, wp, lp
				return stat
		swend
		return 0

	//--------------------------------------------------------------------------
	// 内部用コールバックプロシージャ (イベントフック処理: 位置監視)
	//--------------------------------------------------------------------------
	*__tb_WndProc2
		if _tb_w11 == 0 {
			if _tb_isResizing == 1 { return 0 }
			if _tb_hwndrb == 0 { return 0 }
			dim callbkarg2, 7
			clbkargprotect callbkarg2
			FindWindowEx _tb_hwndTaskBar, 0, "ReBarWindow32", NULL
			newhwndrb = stat
			if newhwndrb == 0 { return 0 }
			dim newrecrb, 4
			GetWindowRect newhwndrb, varptr(newrecrb)
			if _tb_isVertical != 0 {
				nowrbHeight = newrecrb(3) - newrecrb(1)
				if nowrbHeight > _tb_rbTargetHeight {
					_tb_isResizing = 1
					MoveWindow _tb_hwndrb, _tb_rbRelX, _tb_rbRelY, _tb_rbTargetWidth, _tb_rbTargetHeight, 0x0001
					_tb_isResizing = 0
				}
			} else {
				nowrbWidth = newrecrb(2) - newrecrb(0)
				if nowrbWidth > _tb_rbTargetWidth {
					_tb_isResizing = 1
					MoveWindow _tb_hwndrb, _tb_rbRelX, 0, _tb_rbTargetWidth, _tb_rectbw_3, 0x0001
					_tb_isResizing = 0
				}
			}
		}
		return 0

#global
