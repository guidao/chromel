;;; web.el --- Native CEF browser buffers for macOS -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Load web.el, then M-x web.  Run scripts/build.sh before first use.
;; Each browser is an in-process Cocoa child view, with CEF renderer helpers.
;; No Qt, external floating window, or patched Emacs is required.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'seq)
(require 'url-parse)
(require 'url-util)

(defgroup web nil "Native browser buffers." :group 'applications)
(defconst web--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))
(defcustom web-native-module (expand-file-name "build/web-module.dylib" web--directory)
  "Compiled native module." :type 'file)
(defcustom web-runtime-directory (expand-file-name "build/WebRuntime.app" web--directory)
  "CEF runtime bundle." :type 'directory)
(defcustom web-data-directory (expand-file-name "web/" user-emacs-directory)
  "Private directory for CEF profile and browsing history.
Do not point this at a Chrome profile.  Restart Emacs after changing it."
  :type 'directory)
(defcustom web-home-url "https://example.org"
  "Page opened by `web' when no URL is supplied." :type 'string)
(defcustom web-history-limit 1000 "Maximum number of saved history entries."
  :type 'natnum)
(defcustom web-closed-tab-limit 30
  "Maximum number of closed pages retained for `web-reopen-closed-tab'."
  :type 'natnum)
(defcustom web-session-auto-save t
  "Automatically save browser tabs after changes and on Emacs exit."
  :type 'boolean)
(defcustom web-hint-alphabet "asdfghjklqwertyuiopzxcvbnm"
  "Distinct lowercase ASCII letters used for interactive element labels."
  :type 'string)
(defcustom web-scroll-step 60
  "Distance in CSS pixels scrolled by one j or k command."
  :type 'natnum)
(defcustom web-scroll-duration 140
  "Approximate smooth scrolling duration in milliseconds.
Set to zero for instant scrolling.  The system reduced-motion preference
also disables animation.  Separate commands accumulate their distance.
Held j/k use `web-scroll-speed` after the initial step."
  :type 'natnum)

(defcustom web-scroll-speed 900
  "Continuous j/k scrolling speed in CSS pixels per second."
  :type 'natnum)
(defvar-local web--scroll-settings nil)

(declare-function web--native-init "web-module" (bundle profile))
(declare-function web--native-bind "web-module" (title))
(declare-function web--native-create "web-module" (window url))
(declare-function web--native-layout "web-module" (id window x y width height))
(declare-function web--native-hide "web-module" (id))
(declare-function web--native-command "web-module" (id action argument))
(declare-function web--native-pump "web-module" ())
(declare-function web--native-events "web-module" ())
(declare-function web--native-shutdown "web-module" ())
(declare-function web--native-info "web-module" ())
(declare-function web--native-inspect "web-module" (id))

(defvar web--initialized nil)
(defvar web--timer nil)
(defvar web--syncing nil)
(defvar web--pages (make-hash-table :test #'eql))
(defvar web--frames (make-hash-table :test #'eq :weakness 'key))
(defvar web--history nil)
(defvar web--history-loaded nil)
(defvar web--history-timer nil)
(defvar web--tabs nil)
(defvar web--closed-tabs nil)
(defvar web--last-selected-tab nil)
(defvar web--session-loaded nil)
(defvar web--previous-session nil)
(defvar web--session-restored nil)
(defvar web--session-backed-up nil)
(defvar web--session-active nil)
(defvar web--session-dirty nil)
(defvar web--session-timer nil)
(defvar web--session-inhibit nil)
(defvar web--shutting-down nil)
(defvar web--eval-counter 0)
(defvar-local web--id nil)
(defvar-local web--pending nil)
(defvar-local web--activation-error nil)
(defvar-local web--url "")
(defvar-local web--title "Browser")
(defvar-local web--status "")
(defvar-local web--window nil)
(defvar-local web--find-token nil)
(defvar-local web--find-reply nil)
(defvar-local web--find-text "")
(defvar-local web--find-active nil)
(defvar-local web--find-count 0)
(defvar-local web--find-ordinal 0)
(defvar-local web--find-status "")
(defvar-local web--eval-token nil)
(defvar-local web--eval-reply nil)

(defun web--normalize-url (input)
  "Convert INPUT to a navigable URL.  Whitespace-separated input is a search."
  (setq input (string-trim input))
  (cond ((string-empty-p input) web-home-url)
        ((string-match-p "\\`\\(?:[[:alpha:]][[:alnum:]+.-]*://\\|about:\\|data:\\)" input) input)
        ((file-name-absolute-p input)
         (concat "file://" (url-encode-url (expand-file-name input))))
        ((string-match-p "[[:space:]]" input)
         (concat "https://duckduckgo.com/?q=" (url-hexify-string input)))
        ((string-match-p "\\`\\(?:localhost\\|127\\.0\\.0\\.1\\|\\[::1\\]\\)\\(?::[0-9]+\\)?\\(?:/\\|\\'\\)" input)
         (concat "http://" input))
        (t (concat "https://" input))))

(defun web--header-url (url)
  "Shorten HTTP(S) URL to its origin and an ellipsis for hidden details."
  (save-match-data
    (if (string-match "\\`\\(https?://[^/?#]+\\)\\(.*\\)\\'" url)
        (concat (match-string 1 url)
                (unless (member (match-string 2 url) '("" "/")) "/..."))
      url)))

(defconst web--header-line-format '(:eval (concat " " (web--header-url web--url))))

(defun web--start ()
  (web--session-load)
  (unless web--initialized
    (unless (and (eq system-type 'darwin) (eq window-system 'ns)
                 (fboundp 'module-load))
      (user-error "Web requires a Cocoa Emacs with dynamic module support"))
    (unless (file-exists-p web-native-module)
      (user-error "Build the module first: cd %s && ./scripts/build.sh" web--directory))
    (make-directory web-data-directory t)
    (set-file-modes web-data-directory #o700)
    (module-load web-native-module)
    ;; Chromium's macOS sandbox authorizes MainBundlePath, not CEF's outer
    ;; bundle override.  The launcher supplies an unchanged Emacs binary in
    ;; a private bundle with the framework physically inside it.
    (let ((host (expand-file-name "../.." invocation-directory)))
      (when (file-directory-p
             (expand-file-name "Contents/Frameworks/Chromium Embedded Framework.framework" host))
        (setq web-runtime-directory host)))
    (web--native-init (directory-file-name (expand-file-name web-runtime-directory))
                      (expand-file-name "profile" web-data-directory))
    (setq web--initialized t)
    (web--history-load)
    (add-hook 'window-size-change-functions #'web--sync)
    (add-hook 'window-buffer-change-functions #'web--sync)
    (add-hook 'window-selection-change-functions #'web--sync)
    (add-hook 'window-configuration-change-hook #'web--sync)
    (add-hook 'minibuffer-setup-hook #'web--release-focus)
    (add-hook 'delete-frame-functions #'web--frame-deleting)
    (add-hook 'kill-emacs-hook #'web--shutdown)
    (setq web--timer (run-at-time 0 0.02 #'web--tick))))

(defun web--frame-handle (frame)
  "Bind FRAME to an NSWindow without depending on private Emacs structs."
  (or (gethash frame web--frames)
      (let ((old (frame-parameter frame 'title))
            (token (format "emacs-web-%s-%s" (emacs-pid) (make-temp-name "frame-"))))
        (unwind-protect
            (progn
              ;; NS `window-id' is an Emacs counter, not an NSWindow pointer.
              (set-frame-parameter frame 'title token)
              (let ((handle (web--native-bind token)))
                (puthash frame handle web--frames)
                handle))
          (set-frame-parameter frame 'title old)))))

(defun web--display-window (buffer)
  "Choose one visible window for BUFFER, preferring the selected window."
  (let ((windows (get-buffer-window-list buffer nil t)))
    (or (and (memq (selected-window) windows) (selected-window))
        (cl-find-if (lambda (w) (eq t (frame-visible-p (window-frame w)))) windows))))

(defun web--sync (&rest _)
  "Synchronize native views with Emacs windows, in Cocoa logical points."
  (when (and web--initialized (not web--syncing) (not web--shutting-down))
    (let* ((web--syncing t)
           (selected (window-buffer (selected-window))))
      (when (and (not web--session-inhibit) (not web--shutting-down)
                 (not (active-minibuffer-window)) (memq selected (web--buffers)))
        (with-current-buffer selected
          (when (and web--pending (not web--activation-error))
            (condition-case err
                (web--ensure-browser)
              (error
               (setq web--activation-error (error-message-string err)
                     web--status "Load failed; r to retry")
               (message "Web: %s" web--activation-error)))))
        (unless (eq selected web--last-selected-tab)
          (setq web--last-selected-tab selected)
          (web--session-changed)))
      (maphash
       (lambda (id buffer)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (let ((win (web--display-window buffer)))
               (setq web--window win)
               (let ((settings (list web-scroll-step web-scroll-duration web-scroll-speed)))
                 (unless (equal settings web--scroll-settings)
                   (web--native-command id "scroll-settings" (web--json (vconcat settings)))
                   (setq web--scroll-settings settings)))
               ;; Cocoa may consume Escape before Emacs keymaps see it.  Tell
               ;; the native event router which buffer owns command input.
               (web--native-command id "selected"
                                    (if (and (eq win (selected-window))
                                             (not (active-minibuffer-window))) "1" "0"))
               (if (and win (eq t (frame-visible-p (window-frame win))))
                   (pcase-let ((`(,left ,top ,right ,bottom)
                                (window-inside-pixel-edges win)))
                     (web--native-layout id (web--frame-handle (window-frame win))
                                         left top (- right left) (- bottom top))
                     (unless (and (eq win (selected-window))
                                  (not (active-minibuffer-window)))
                       (web--native-command id "unfocus" "")))
                 (web--native-hide id))))))
       web--pages))))

(defun web--release-focus ()
  (when web--initialized
    (maphash (lambda (id _)
               (web--native-command id "selected" "0")
               (web--native-command id "unfocus" "")) web--pages)))

(defun web--frame-deleting (frame)
  (maphash
   (lambda (id buffer)
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (when (and (window-live-p web--window)
                    (eq frame (window-frame web--window)))
           (web--native-hide id)
           (setq web--window nil)))))
   web--pages)
  (remhash frame web--frames))

(defun web--handle-event (event)
  (let* ((id (plist-get event :id))
         (buffer (gethash id web--pages))
         (type (plist-get event :type))
         (value (or (plist-get event :value) "")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (pcase type
          ("title"
           (setq web--title value)
           (rename-buffer (format "*web: %s*" (truncate-string-to-width value 60)) t))
          ("url"
           (unless (equal value web--url)
             (setq web--find-active nil web--find-status ""))
           (setq web--url value))
          ("loading" (setq web--status (if (equal value "1") "Loading" "")))
          ("loaded" (web--history-record web--url web--title))
          ("error" (setq web--status value))
          ("focus"
           (when (and (window-live-p web--window) (not (active-minibuffer-window)))
             (select-window web--window)))
          ("scroll-key"
           (let ((request (json-parse-string value :object-type 'plist)))
             (web--scroll (plist-get request :steps) (plist-get request :frame))))
          ("find"
           (let ((reply (json-parse-string value :object-type 'plist)))
             (when (equal web--find-token (plist-get reply :token))
               (when (>= (plist-get reply :count) 0)
                 (setq web--find-count (plist-get reply :count)))
               (when (>= (plist-get reply :ordinal) 0)
                 (setq web--find-ordinal (plist-get reply :ordinal)))
               (when (eq t (plist-get reply :final)) (setq web--find-reply reply)))))
          ("popup-background" (web value t))
          ("popup"
           ;; Select the new buffer while keeping browser commands available.
           (with-current-buffer (web value) (web--command "unfocus")))
          ("eval"
           (let ((reply (json-parse-string value :object-type 'plist)))
             (when (equal web--eval-token (plist-get reply :token))
               (setq web--eval-reply reply))))
          ("closed"
           (remhash id web--pages)
           (setq web--id nil web--status "Closed")
           (web--kill-buffer)))
        (when (member type '("title" "url")) (web--session-changed))
        (force-mode-line-update)))))

(defun web--tick ()
  (when web--initialized
    (condition-case err
        (progn
          (web--native-pump)
          (dolist (event (json-parse-string (web--native-events)
                                            :object-type 'plist :array-type 'list))
            (web--handle-event event))
          (web--sync))
      (error
       ;; Avoid repeated native errors at 50 Hz.  `web-resume' retries explicitly.
       (cancel-timer web--timer)
       (setq web--timer nil)
       (message "Web paused: %s (M-x web-resume to retry)" (error-message-string err))))))

(defun web-resume ()
  "Resume the browser event pump after a reported error."
  (interactive)
  (unless web--initialized (user-error "Web has not started"))
  (unless web--timer (setq web--timer (run-at-time 0 0.02 #'web--tick))))

(defun web--kill-buffer ()
  (let* ((buffer (current-buffer))
         (index (cl-position buffer (web--buffers))))
    (when (and index (not web--session-inhibit) (not web--shutting-down)
               (> web-closed-tab-limit 0) (not (string-empty-p web--url)))
      (push (list :url web--url :title web--title :index index) web--closed-tabs)
      (setq web--closed-tabs (seq-take web--closed-tabs web-closed-tab-limit)))
    (when web--id
      (web--native-command web--id "close" "")
      (remhash web--id web--pages))
    (setq web--id nil web--pending nil
          web--tabs (delq buffer web--tabs))
    (when index (web--session-changed))))

(defun web--shutdown ()
  ;; Save before native shutdown or buffer teardown can discard tab state.
  (when (timerp web--session-timer) (cancel-timer web--session-timer))
  (setq web--session-timer nil)
  (when (and web-session-auto-save web--session-active)
    (web--session-save-quietly))
  (setq web--shutting-down t)
  (when (timerp web--timer) (cancel-timer web--timer))
  (when (timerp web--history-timer) (cancel-timer web--history-timer))
  (web--history-save)
  (when web--initialized
    ;; Let Emacs dispatch Cocoa events between close requests and CefShutdown.
    ;; Blocking inside the native shutdown loop alone can leave AppKit window
    ;; teardown pending and skip CEF's profile flush when tabs are still open.
    (web--native-command 0 "close-settings" "")
    (dolist (buffer (web--buffers))
      (with-current-buffer buffer (ignore-errors (web--kill-buffer))))
    (let ((deadline (+ (float-time) 3)))
      (while (and (< (float-time) deadline)
                  (let ((info (web--native-info)))
                    (not (and (string-match-p "Browsers including DevTools: 0" info)
                              (string-match-p "Settings windows: 0" info)))))
        (web--native-pump)
        (accept-process-output nil 0.01)))
    (web--native-shutdown)))

(defvar web-mode-map (make-sparse-keymap)
  "Browser commands, following Vimium's default keys.")

;; Clear the early layout on reload, particularly g before making it a prefix.
(dolist (key '("g" "b" "h"))
  (define-key web-mode-map (kbd key) nil))
(dolist (entry '(("r" . web-reload) ("gg" . web-scroll-to-top)
                 ("G" . web-scroll-to-bottom) ("H" . web-back) ("L" . web-forward)
                 ("j" . web-scroll-down) ("k" . web-scroll-up)
                 ("d" . web-scroll-half-page-down) ("u" . web-scroll-half-page-up)
                 ("f" . web-follow) ("F" . web-follow-background)
                 ("M-f" . web-follow-multiple) ("yy" . web-copy-url) ("yf" . web-copy-link)
                 ("/" . web-find) ("n" . web-find-next) ("N" . web-find-previous)
                 ("o" . web-open) ("O" . web-open-new-url)
                 ("ge" . web-open-url) ("gE" . web-edit-url-new-buffer)
                 ("p" . web-open-copied-url) ("P" . web-open-copied-url-new-buffer)
                 ("t" . web-new-tab) ("x" . web-close-tab) ("X" . web-reopen-closed-tab)
                 ("J" . web-previous-tab) ("K" . web-next-tab)
                 ("gT" . web-previous-tab) ("gt" . web-next-tab)
                 ("T" . web-switch-tab) ("^" . web-last-tab)
                 ("gF" . web-focus-main-frame)
                 ("i" . web-focus) ("RET" . web-focus) ("q" . quit-window)
                 ("M-<" . web-scroll-to-top) ("M->" . web-scroll-to-bottom)
                 ("M-<right>" . web-forward)
                 ("C-c C-f" . web-forward) ("C-c C-j" . web-follow)
                 ("C-c C-o" . web-open-url) ("C-c C-r" . web-reload)
                 ("C-c C-i" . web-focus) ("C-c C-d" . web-devtools)
                 ("C-c C-p" . web-focus-parent-frame)))
  (define-key web-mode-map (kbd (car entry)) (cdr entry)))

;; Motion leaves other browser keys to the major mode.  Only adapt the two
;; movement commands commonly configured in Meow; keep SPC/keypad untouched.
(define-key web-mode-map [remap meow-next] #'web-scroll-down)
(define-key web-mode-map [remap meow-prev] #'web-scroll-up)
(defvar meow-mode-state-list)
(with-eval-after-load 'meow
  ;; Respect an explicit user preference, and support either load order.
  (unless (assq 'web-mode meow-mode-state-list)
    (push '(web-mode . motion) meow-mode-state-list)))

;; These remain accessible when the native page owns keyboard focus.
(defvar web-actions-map (make-sparse-keymap))
(dolist (entry '(("s" . web-find) ("n" . web-find-next) ("p" . web-find-previous)
                 ("c" . web-find-clear) ("d" . web-scroll-half-page-down)
                 ("u" . web-scroll-half-page-up) ("<" . web-scroll-to-top)
                 (">" . web-scroll-to-bottom) ("y" . web-copy-url)
                 ("f" . web-copy-link) ("m" . web-follow-multiple)
                 ("h" . web-history) ("," . web-settings) ("S" . web-save-session) ("R" . web-restore-session)))
  (define-key web-actions-map (kbd (car entry)) (cdr entry)))
(define-key web-mode-map (kbd "C-c w") web-actions-map)

(define-derived-mode web-mode special-mode "Web"
  "CEF browser buffer.  Press i to focus the page, Esc or C-g to return to Emacs.
One native view can occupy only one Emacs window at a time."
  ;; Translate the dedicated Escape key before Meow/emulation keymaps.  Keep
  ;; the ESC prefix (used for Meta sequences) and all other buffers unchanged.
  (setq-local key-translation-map (if (keymapp key-translation-map)
                                      (copy-keymap key-translation-map)
                                    (make-sparse-keymap)))
  (define-key key-translation-map [escape] (kbd "C-g"))
  (setq-local cursor-type nil)
  (setq-local truncate-lines t)
  (setq-local header-line-format web--header-line-format)
  (setq-local mode-line-process '(:eval (concat " " web--status web--find-status)))
  (add-hook 'kill-buffer-hook #'web--kill-buffer nil t)
  (add-hook 'change-major-mode-hook #'web--kill-buffer nil t)
  (let ((inhibit-read-only t))
    (insert "This browser view is displayed in one Emacs window at a time.\n"
            "Select this window to move the view here.\n\n"
            "i: focus page   Esc/C-g: return to Emacs   o: URL   r: reload\n"
            "j: scroll down   k: scroll up\n"
            "C-c C-p: parent page   C-u C-c C-p: outermost page\n"
            "f: click/focus hints   F: open links in the background\n")))

(defun web--make-tab (url title &optional position)
  "Create a deferred tab with exact URL and TITLE at POSITION, or at the end."
  (let* ((buffer (generate-new-buffer "*web*"))
         (tabs (web--buffers))
         (index (min (or position (length tabs)) (length tabs))))
    (with-current-buffer buffer
      (web-mode)
      (setq web--url url web--title title web--pending t web--status "Not loaded")
      (rename-buffer (format "*web: %s*" (truncate-string-to-width title 60)) t))
    (setq web--tabs (append (seq-take tabs index) (list buffer) (nthcdr index tabs)))
    buffer))

(defun web--ensure-browser ()
  "Materialize the current deferred tab exactly once.  Errors leave it retryable."
  (when web--pending
    (web--start)
    (let* ((web--syncing t)
           (window (web--display-window (current-buffer)))
           (id (web--native-create (web--frame-handle
                                    (if window (window-frame window) (selected-frame)))
                                  web--url)))
      (setq web--id id web--pending nil web--activation-error nil web--status "Loading")
      (puthash id (current-buffer) web--pages))))

;;;###autoload
(defun web-settings (&optional url)
  "Open or raise Chromium settings in a separate native window.
The window shares this plugin's profile with embedded pages.  Optional
URL selects a chrome://settings subpage; omitted URL preserves the current
settings page.  Works from any buffer and does not create a browser tab."
  (interactive)
  (when (and url (not (web--settings-url-p url)))
    (user-error "Expected a chrome://settings URL"))
  (web--start)
  (web--native-command 0 "settings"
                       (if url (concat "chrome://settings" (substring url 17)) "")))

(defun web--settings-url-p (url)
  "Return non-nil if URL belongs to Chromium's settings WebUI."
  (and (stringp url)
       (let ((case-fold-search t))
         (string-match-p "\\`chrome://settings\\(?:[/?#]\\|\\'\\)" url))))

;;;###autoload
(defun web (&optional url background)
  "Open URL in a new browser buffer.
With BACKGROUND non-nil, leave the selected buffer and keyboard focus alone.
Settings URLs open a separate settings window and return nil."
  (interactive (list (read-string "URL or search: " nil nil web-home-url)))
  (setq url (web--normalize-url (or url web-home-url)))
  (if (web--settings-url-p url)
      (progn (web-settings url) nil)
    (web--start)
    (let (buffer)
      (let ((web--session-inhibit t))
        (condition-case err
            (progn
              (setq buffer (web--make-tab url "Browser"))
              (unless background (pop-to-buffer buffer))
              (with-current-buffer buffer
                (web--ensure-browser)
                (web--sync)
                (unless (or background (active-minibuffer-window)) (web-focus)))
              (unless background (setq web--last-selected-tab buffer)))
          ((error quit)
           (when (buffer-live-p buffer) (kill-buffer buffer))
           (signal (car err) (cdr err)))))
      (web--session-changed)
      buffer)))

(defun web--command (action &optional argument)
  (web--ensure-browser)
  (unless web--id (user-error "This is not a live Web buffer"))
  (web--native-command web--id action (or argument "")))

(defun web-open-url (url)
  "Navigate the current browser to URL."
  (interactive (list (read-string "URL or search: " web--url)))
  (setq url (web--normalize-url url))
  (if (web--settings-url-p url)
      (web-settings url)
    (web--command "navigate" url)))
(defvar web-url-history nil)

(defun web--read-url (&optional initial)
  "Read an address or search, completing visited URLs, with INITIAL text."
  (web--history-load)
  (completing-read "URL or search: "
                   (delete-dups (mapcar (lambda (item) (plist-get item :url)) web--history))
                   nil nil initial 'web-url-history))

(defun web-open (url)
  "Open URL in the current page, completing previously visited addresses."
  (interactive (list (web--read-url)))
  (web-open-url url))

(defun web--buffers ()
  "Return browser tabs in tab order, including deferred restored pages."
  ;; Include pre-existing native pages when reloading from an older version.
  (let ((tabs (cl-remove-if-not #'buffer-live-p web--tabs)))
    (append tabs
            (mapcar #'cdr
                    (sort (cl-loop for id being the hash-keys of web--pages using (hash-values buffer)
                                   when (and (buffer-live-p buffer) (not (memq buffer tabs)))
                                   collect (cons id buffer))
                          (lambda (a b) (< (car a) (car b))))))))

(defun web--select-buffer (buffer)
  "Select browser BUFFER in this window, retaining Emacs command focus."
  (unless (memq buffer (web--buffers)) (user-error "Browser buffer is no longer live"))
  (web--release-focus)
  (switch-to-buffer buffer)
  (web--ensure-browser)
  (web--sync)
  (web--command "unfocus")
  (setq web--last-selected-tab buffer)
  (web--session-changed))

(defun web-open-new-url (url)
  "Open URL in a new selected browser buffer, retaining command focus."
  (interactive (list (web--read-url)))
  (when-let* ((buffer (web url t)))
    (web--select-buffer buffer)))

(defun web-edit-url-new-buffer (url)
  "Edit this page's address and open URL in a new browser buffer."
  (interactive (list (web--read-url web--url)))
  (web-open-new-url url))

(defun web-new-tab ()
  "Open `web-home-url' in a new selected browser buffer."
  (interactive)
  (web-open-new-url web-home-url))

(defun web-open-copied-url (&optional new-buffer)
  "Open the latest kill or clipboard text as an address or search.
With NEW-BUFFER, use a new selected browser buffer.  Follow Emacs clipboard
settings through `current-kill', just as `yank' does."
  (interactive "P")
  (let ((text (current-kill 0 t)))
    (when (string-empty-p (string-trim text)) (user-error "Copied text is empty"))
    (if new-buffer (web-open-new-url text) (web-open-url text))))

(defun web-open-copied-url-new-buffer ()
  "Open the copied address or search in a new selected browser buffer."
  (interactive)
  (web-open-copied-url t))

(defun web-next-tab (&optional count)
  "Select the browser COUNT places ahead in tab order, wrapping at the end."
  (interactive "p")
  (let* ((buffers (web--buffers))
         (index (cl-position (current-buffer) buffers)))
    (unless index (user-error "This is not a live Web buffer"))
    (web--select-buffer (nth (mod (+ index (or count 1)) (length buffers)) buffers))))

(defun web-previous-tab (&optional count)
  "Select the browser COUNT places back in tab order."
  (interactive "p")
  (web-next-tab (- (or count 1))))

(defun web-switch-tab ()
  "Choose a live browser buffer by title or address."
  (interactive)
  (let ((choices (mapcar (lambda (buffer)
                           (cons (format "%s  %s" (buffer-name buffer)
                                         (buffer-local-value 'web--url buffer)) buffer))
                         (web--buffers))))
    (unless choices (user-error "No live browser buffers"))
    (web--select-buffer (cdr (assoc (completing-read "Browser: " choices nil t) choices)))))

(defun web-last-tab ()
  "Select the most recently visited other live browser buffer."
  (interactive)
  (let* ((buffers (web--buffers))
         (previous (cl-find-if (lambda (buffer)
                                (and (not (eq buffer (current-buffer)))
                                     (memq buffer buffers)))
                              (buffer-list))))
    (unless previous (user-error "No previous browser buffer"))
    (web--select-buffer previous)))

(defun web-close-tab ()
  "Close this browser buffer and select the next one, if any."
  (interactive)
  (let* ((source (current-buffer))
         (buffers (web--buffers))
         (index (cl-position source buffers))
         (next (and index (> (length buffers) 1)
                    (nth (mod (1+ index) (length buffers)) buffers))))
    (unless index (user-error "This is not a live Web buffer"))
    (when (kill-buffer source)
      (when (and next (memq next (web--buffers))) (web--select-buffer next)))))

(defun web-reload () "Reload the current page." (interactive) (web--command "reload"))
(defun web-back () "Go back." (interactive) (web--command "back"))
(defun web-forward () "Go forward." (interactive) (web--command "forward"))
(defun web-stop () "Stop loading." (interactive) (web--command "stop"))
(defun web-focus () "Send keyboard focus to the page." (interactive) (web--command "focus"))
(defun web-devtools () "Open Chromium developer tools." (interactive) (web--command "devtools"))

(defun web-focus-parent-frame (&optional root)
  "Return scrolling to the parent of the currently focused iframe.
With prefix ROOT, return directly to the outermost page.  Keep Emacs
command focus so j/k operate on the new target."
  (interactive "P")
  (web--command "focus-parent" (if root "root" "parent"))
  (message "Web: returning to %s page" (if root "outermost" "parent")))

(defun web-focus-main-frame ()
  "Return scrolling to the outermost page, retaining command focus."
  (interactive)
  (web-focus-parent-frame t))

(defun web--scroll (steps &optional frame mode held)
  "Scroll STEPS in FRAME or the focused frame, using optional MODE.
HELD permits physical j/k hold tracking after the Emacs keymap chose scrolling."
  (unless (and (natnump web-scroll-step) (natnump web-scroll-duration)
               (natnump web-scroll-speed))
    (user-error "Scroll step, duration and speed must be nonnegative integers"))
  (web--command "scroll"
                (web--json (list :amount (if (or (null mode) (equal mode "pixels"))
                                             (* steps web-scroll-step) steps)
                                 :duration web-scroll-duration :speed web-scroll-speed
                                 :mode (or mode "pixels") :frame (or frame "")
                                 :held (if held t :false)))))

(defun web-scroll-down (&optional count)
  "Scroll the page down COUNT steps, keeping Emacs command focus.
Use the focused frame, including cross-origin iframes.  Scroll a focused
control's scrollable ancestor first, then that frame's page."
  (interactive "p")
  (web--scroll (or count 1) nil nil
               (and (called-interactively-p 'any) (not current-prefix-arg)
                    (equal (this-command-keys-vector) [106]))))

(defun web-scroll-up (&optional count)
  "Scroll the page up COUNT steps, keeping Emacs command focus."
  (interactive "p")
  (web--scroll (- (or count 1)) nil nil
               (and (called-interactively-p 'any) (not current-prefix-arg)
                    (equal (this-command-keys-vector) [107]))))

(defun web--json (object)
  "Serialize OBJECT as JSON text suitable for the native UTF-8 interface."
  (decode-coding-string (json-serialize object) 'utf-8-unix))

(defun web--eval (script)
  "Evaluate SCRIPT in this page and parse its JSON string result.
Only Emacs can initiate this request; no Lisp interface is exposed to pages."
  (unless web--id (user-error "This is not a live Web buffer"))
  (when web--eval-token (user-error "A page request is already pending"))
  (let ((deadline (+ (float-time) 5))
        (id web--id))
    (setq web--eval-token (format "web-js-%d" (cl-incf web--eval-counter))
          web--eval-reply nil)
    (unwind-protect
        (progn
          (web--command "eval" (web--json (list :token web--eval-token :script script)))
          (while (and (not web--eval-reply) (eql id web--id)
                      (< (float-time) deadline))
            (web--tick)
            (unless web--eval-reply (accept-process-output nil 0.01)))
          (unless web--eval-reply
            (user-error "Page did not respond; wait for it to load and retry (updated Helper requires restarting Emacs)"))
          (unless (eq t (plist-get web--eval-reply :ok))
            (user-error "Page: %s" (plist-get web--eval-reply :result)))
          (json-parse-string (plist-get web--eval-reply :result)
                             :object-type 'plist :array-type 'list))
      (setq web--eval-token nil web--eval-reply nil))))

(defun web--hint-script ()
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents (expand-file-name "native/hints.js" web--directory)))
    (buffer-string)))

(defun web--hint-call (session method &optional argument)
  "Call METHOD on the hint overlay belonging to SESSION."
  (format "JSON.stringify((()=>{const h=window.__emacsWebHints;if(!h||h.session!==%s)return false;return h.%s(%s);})())"
          (web--json session) method (if argument (web--json argument) "")))

(defun web--read-hint (hints session)
  "Read a label from HINTS, narrowing the overlay for SESSION."
  (let ((prefix "") chosen)
    (while (not chosen)
      (let* ((event (read-key (format "Hint%s: %s  (C-g cancels)"
                                      (if (string-empty-p prefix) "" " label") prefix)))
             (next (cond ((memq event '(7 27 escape)) (keyboard-quit))
                         ((memq event '(127 8 backspace delete))
                          (substring prefix 0 (max 0 (1- (length prefix)))))
                         ((and (characterp event) (<= ?a event ?z))
                          (concat prefix (string event)))
                         (t prefix)))
             (matches (cl-remove-if-not
                       (lambda (hint) (string-prefix-p next (plist-get hint :label))) hints)))
        (when matches
          (setq prefix next)
          (unless (eq t (web--eval (web--hint-call session "filter" prefix)))
            (user-error "Page moved or changed; invoke hints again"))
          (setq chosen (cl-find prefix matches :key (lambda (hint) (plist-get hint :label))
                                :test #'equal)))))
    chosen))

(defun web--validate-hint-alphabet ()
  (unless (and (string-match-p "\\`[a-z]+\\'" web-hint-alphabet)
               (> (length web-hint-alphabet) 1)
               (= (length web-hint-alphabet) (length (delete-dups (string-to-list web-hint-alphabet)))))
    (user-error "web-hint-alphabet must contain at least two distinct lowercase letters")))

(defun web-follow (&optional new-buffer background)
  "Label visible interactive elements and activate one by typing its label.
Buttons are clicked and editable controls are focused.  With prefix
NEW-BUFFER, follow ordinary links in a new buffer.  With BACKGROUND as well,
leave the source selected.  C-g cancels."
  (interactive "P")
  (web--validate-hint-alphabet)
  (let ((source (current-buffer)) (id web--id)
        (session (format "hints-%d" (cl-incf web--eval-counter))) chosen)
    (web--command "unfocus")
    (unwind-protect
        (let ((hints (web--eval (format "%s(%s,%s)" (web--hint-script)
					(web--json web-hint-alphabet) (web--json session)))))
          (unless hints (user-error "No visible interactive elements on this page"))
          (setq chosen (web--read-hint hints session))
          (let ((action (web--eval (web--hint-call session "prepare" (plist-get chosen :label)))))
            (unless (and (listp action) (member (plist-get action :action) '("focus" "click")))
              (user-error "Element moved, was disabled or disappeared; invoke hints again"))
            (if (equal (plist-get action :action) "focus")
                (web-focus)
              (web--command "click" (web--json
                                     (list :x (plist-get action :x) :y (plist-get action :y)
                                           :newBuffer (if (and new-buffer (eq t (plist-get action :link)))
                                                          t :false)
                                           :background (if background t :false)))))))
      (when (buffer-live-p source)
        (with-current-buffer source
          (when (and web--id (eql web--id id))
            (ignore-errors
              (web--command "javascript" (web--hint-call session "clear")))))))))

(defun web-follow-new-buffer ()
  "Activate a hinted element; ordinary links open in a new selected buffer."
  (interactive)
  (web-follow t))

(defun web-follow-background ()
  "Activate a hinted element; ordinary links open in a background buffer."
  (interactive)
  (web-follow t t))

(defvar web-find-history nil)
(defvar web-find-minibuffer-map
  (let ((map (copy-keymap minibuffer-local-map)))
    (define-key map [escape] #'keyboard-quit)
    map))

(defun web-find-clear ()
  "Clear page search highlighting, retaining the last query for n/N."
  (interactive)
  (web--command "find-stop")
  (setq web--find-token nil web--find-reply nil web--find-active nil
        web--find-status "")
  (force-mode-line-update))

(defun web--find-run (text forward next)
  "Search for TEXT, moving FORWARD, continuing the search when NEXT."
  (when web--find-token (user-error "A search is already pending"))
  (web--command "unfocus")
  (let ((deadline (+ (float-time) 5)) (id web--id) complete)
    (setq web--find-token (format "find-%d" (cl-incf web--eval-counter))
          web--find-reply nil web--find-count 0 web--find-ordinal 0)
    (unwind-protect
        (progn
          (web--command "find" (web--json (list :text text :token web--find-token
						:forward (if forward t :false)
						:next (if next t :false))))
          (while (and (not web--find-reply) (eql id web--id) (< (float-time) deadline))
            (web--tick)
            (unless web--find-reply (accept-process-output nil 0.01)))
          (unless web--find-reply (user-error "Page search timed out; try again"))
          (setq web--find-text text web--find-active t complete t
                web--find-status (format "  Find %d/%d" web--find-ordinal web--find-count))
          (force-mode-line-update)
          (message "%s: %d/%d%s" text web--find-ordinal web--find-count
                   (if (zerop web--find-count) " (no matches)" "")))
      (setq web--find-token nil)
      (unless complete (when (eql id web--id) (web-find-clear))))))

(defun web-find (&optional text)
  "Find TEXT in the rendered page, or read it from the minibuffer.
Search is literal and case-insensitive.  RET searches; Esc/C-g cancels
and clears highlights.  Use `web-find-next' or `web-find-previous' to repeat."
  (interactive)
  (let (accepted)
    (unwind-protect
        (progn
          (unless text
            (web--command "unfocus")
            (setq text (read-from-minibuffer "Find in page: " nil web-find-minibuffer-map
                                             nil 'web-find-history web--find-text)))
          (if (string-empty-p text) (web-find-clear) (web--find-run text t nil))
          (setq accepted t))
      (unless accepted (web-find-clear)))))

(defun web-find-next ()
  "Select the next match of this buffer's last page search."
  (interactive)
  (if (string-empty-p web--find-text) (web-find)
    (web--find-run web--find-text t web--find-active)))

(defun web-find-previous ()
  "Select the previous match of this buffer's last page search."
  (interactive)
  (if (string-empty-p web--find-text) (web-find)
    (web--find-run web--find-text nil web--find-active)))

(defun web-scroll-half-page-down (&optional count)
  "Scroll COUNT half-viewports down in the active scrolling region."
  (interactive "p")
  (web--scroll (or count 1) nil "half"))

(defun web-scroll-half-page-up (&optional count)
  "Scroll COUNT half-viewports up in the active scrolling region."
  (interactive "p")
  (web--scroll (- (or count 1)) nil "half"))

(defun web-scroll-to-top ()
  "Scroll to the top of the active region, including iframes and dialogs."
  (interactive)
  (web--scroll -1 nil "top"))

(defun web-scroll-to-bottom ()
  "Scroll to the bottom of the active region, including iframes and dialogs."
  (interactive)
  (web--scroll 1 nil "bottom"))

(defun web-copy-url ()
  "Copy the current page URL using Emacs kill-ring/clipboard settings."
  (interactive)
  (unless web--id (user-error "This is not a live Web buffer"))
  (kill-new web--url)
  (message "Copied: %s" web--url))

(defun web--link-hints (multiple)
  "Copy a hinted link, or open links in background buffers when MULTIPLE."
  (web--validate-hint-alphabet)
  (let ((source (current-buffer)) (id web--id)
        (session (format "hints-%d" (cl-incf web--eval-counter)))
        (count 0))
    (web--command "unfocus")
    (unwind-protect
        (let ((hints (web--eval (format "%s(%s,%s,%s)" (web--hint-script)
					(web--json web-hint-alphabet) (web--json session)
					(web--json (if multiple "queue" "copy"))))))
          (unless hints (user-error "No visible links on this page"))
          (catch 'done
            (while t
              (let* ((chosen (web--read-hint hints session))
                     (link (web--eval (web--hint-call session "link" (plist-get chosen :label)))))
                (unless (and (listp link) (stringp (plist-get link :url)))
                  (user-error "Link moved or disappeared; invoke hints again"))
                (if multiple
                    (progn
                      (web--command "click" (web--json (list :x (plist-get link :x) :y (plist-get link :y)
                                                             :newBuffer t :background t)))
                      (cl-incf count)
                      (unless (eq t (web--eval (web--hint-call session "filter" "")))
                        (user-error "Page changed; invoke hints again"))
                      (message "Link sent to background (%d); choose another or Esc to finish" count))
                  (kill-new (plist-get link :url))
                  (message "Copied: %s" (plist-get link :url))
                  (throw 'done t))))))
      (when (buffer-live-p source)
        (with-current-buffer source
          (when (eql id web--id)
            (ignore-errors (web--command "javascript" (web--hint-call session "clear")))))))))

(defun web-copy-link ()
  "Select a link by hint and copy its current URL without clicking it."
  (interactive)
  (web--link-hints nil))

(defun web-follow-multiple ()
  "Repeatedly select links to open in background buffers; Esc/C-g finishes.
Keep the source selected.  Use ordinary HTTP, HTTPS or file links; site
click handlers can still prevent navigation.  Hint labels remain stable."
  (interactive)
  (condition-case nil (web--link-hints t)
    (quit (message "Finished opening links"))))

(defun web--session-read (file)
  "Read and validate FILE without evaluating any Lisp.  Signal on bad data."
  (let* ((coding-system-for-read 'utf-8-unix)
         (data (with-temp-buffer
                 (insert-file-contents file)
                 (json-parse-buffer :object-type 'plist :array-type 'array)))
         (tabs (plist-get data :tabs))
         (closed (plist-get data :closed))
         (selected (plist-get data :selected)))
    (unless (and (listp data) (eql (plist-get data :version) 1)
                 (vectorp tabs) (vectorp closed) (natnump selected)
                 (< selected (max 1 (length tabs)))
                 (cl-every (lambda (entry)
                             (and (listp entry) (stringp (plist-get entry :url))
                                  (not (string-empty-p (plist-get entry :url)))
                                  (stringp (plist-get entry :title))))
                           (append tabs closed nil))
                 (cl-every (lambda (entry) (natnump (plist-get entry :index))) closed))
      (error "Invalid or unsupported Web session: %s" file))
    data))

(defun web--session-load ()
  "Capture the previous run before the first page can overwrite its session."
  (unless web--session-loaded
    (condition-case err
        (let ((file (expand-file-name "session.json" web-data-directory)))
          (when (file-exists-p file)
            (setq web--previous-session (web--session-read file)
                  web--closed-tabs (seq-take (append (plist-get web--previous-session :closed) nil)
                                             web-closed-tab-limit)))
          (setq web--session-loaded t))
      (error
       ;; Do not silently replace corrupt, unreadable or newer-format data.
       (setq web--session-loaded 'failed)
       (message "Web session preserved without overwriting: %s" (error-message-string err))))))

(defun web--session-snapshot ()
  "Return a versioned snapshot including deferred pages and closed-page history."
  (let* ((buffers (web--buffers))
         (selected (window-buffer (selected-window)))
         (index (or (cl-position selected buffers)
                    (cl-position web--last-selected-tab buffers) 0)))
    (list :version 1 :selected index
          :tabs (vconcat (mapcar (lambda (buffer)
                                  (with-current-buffer buffer
                                    (list :url web--url :title web--title))) buffers))
          :closed (vconcat web--closed-tabs))))

(defun web--session-write (name data)
  "Atomically write DATA as UTF-8 JSON to NAME in `web-data-directory'."
  (make-directory web-data-directory t)
  (set-file-modes web-data-directory #o700)
  (let ((temp (make-temp-file (expand-file-name ".session-" web-data-directory))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (with-temp-file temp
              (set-buffer-multibyte nil)
              (insert (json-serialize data))))
          (set-file-modes temp #o600)
          (rename-file temp (expand-file-name name web-data-directory) t))
      (when (file-exists-p temp) (delete-file temp)))))

(defun web-save-session ()
  "Save current tabs, selected page and closed-page history to session.json.
URLs and titles are saved, not page contents, form input or navigation stacks."
  (interactive)
  (web--session-load)
  (unless (eq web--session-loaded t)
    (user-error "Session file could not be read; preserving it without overwriting"))
  (unless (or web--session-active (web--buffers))
    (user-error "No current browser session to save"))
  (unless web--session-backed-up
    (when web--previous-session
      (web--session-write "session.previous.json" web--previous-session))
    (setq web--session-backed-up t))
  (web--session-write "session.json" (web--session-snapshot))
  (setq web--session-dirty nil)
  (when (timerp web--session-timer) (cancel-timer web--session-timer))
  (setq web--session-timer nil)
  (when (called-interactively-p 'interactive) (message "Web session saved")))

(defun web--session-save-quietly ()
  (setq web--session-timer nil)
  (when (and web-session-auto-save (eq web--session-loaded t) web--session-active)
    (condition-case err
        (web-save-session)
      (error (message "Web session save failed: %s" (error-message-string err))))))

(defun web--session-changed ()
  "Coalesce changes into a save within one second, without waiting for idle."
  (unless (or web--session-inhibit web--shutting-down)
    (setq web--session-active t web--session-dirty t)
    (when (and web-session-auto-save (eq web--session-loaded t)
               (not (timerp web--session-timer)))
      (setq web--session-timer (run-at-time 1 nil #'web--session-save-quietly)))))

(defun web-reopen-closed-tab ()
  "Restore the latest closed page at its former tab position and select it.
Also works after C-x k, and from another buffer when the last page was closed."
  (interactive)
  (web--session-load)
  (unless web--closed-tabs (user-error "No closed browser pages to restore"))
  (let ((entry (car web--closed-tabs)) buffer)
    (let ((web--session-inhibit t))
      (condition-case err
          (progn
            (setq buffer (web--make-tab (plist-get entry :url) (plist-get entry :title)
                                        (plist-get entry :index)))
            (web--select-buffer buffer))
        ((error quit)
         (when (buffer-live-p buffer) (kill-buffer buffer))
         (signal (car err) (cdr err)))))
    ;; Consume only after successful activation; a failed X remains retryable.
    (pop web--closed-tabs)
    (web--session-changed)
    buffer))

(defun web-restore-session ()
  "Restore the previous run's pages once, keeping current pages intact.
Append restored pages in saved order and select the saved current page.
Only that page creates a browser; other pages load when first selected."
  (interactive)
  (web--session-load)
  (unless (eq web--session-loaded t) (user-error "Cannot restore unreadable session.json"))
  (when web--session-restored (user-error "Previous session has already been restored"))
  (let ((entries (plist-get web--previous-session :tabs))
        (selected (plist-get web--previous-session :selected))
        (original (window-buffer (selected-window))) buffers)
    (unless (> (length entries) 0) (user-error "No saved browser pages to restore"))
    (let ((web--session-inhibit t))
      (condition-case err
          (progn
            (mapc (lambda (entry)
                    (push (web--make-tab (plist-get entry :url) (plist-get entry :title)) buffers))
                  entries)
            (setq buffers (nreverse buffers))
            (web--select-buffer (nth selected buffers)))
        ((error quit)
         (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer)))
         (when (buffer-live-p original) (switch-to-buffer original))
         (signal (car err) (cdr err)))))
    (setq web--session-restored t)
    (web--session-changed)
    (message "Restored %d pages; background pages load when selected" (length buffers))
    buffers))

(defun web--history-load ()
  (unless web--history-loaded
    (setq web--history-loaded t)
    (let ((file (expand-file-name "history.json" web-data-directory))
          (coding-system-for-read 'utf-8-unix))
      (when (file-readable-p file)
        (condition-case err
            (with-temp-buffer
              (insert-file-contents file)
              (setq web--history
                    (cl-remove-if-not
                     (lambda (item) (and (stringp (plist-get item :url))
                                         (stringp (plist-get item :title))))
                     (json-parse-buffer :object-type 'plist :array-type 'list))))
          (error
           (setq web--history-loaded nil)
           (message "Web history: %s" (error-message-string err))))))))

(defun web--history-record (url title)
  (when (and (> web-history-limit 0) (string-match-p "\\`https?://" url))
    (setq web--history
          (cons (list :url url :title title :time (float-time))
                (cl-remove url web--history :key (lambda (x) (plist-get x :url))
                           :test #'equal)))
    (when (> (length web--history) web-history-limit)
      (setcdr (nthcdr (1- web-history-limit) web--history) nil))
    (unless (timerp web--history-timer)
      (setq web--history-timer (run-with-idle-timer 1 nil #'web--history-save)))))

(defun web--history-save ()
  (setq web--history-timer nil)
  (when web--history-loaded
    (make-directory web-data-directory t)
    (let ((temp (make-temp-file (expand-file-name ".history-" web-data-directory))))
      (unwind-protect
          (progn
            ;; `json-serialize' already returns UTF-8 bytes.  Keep them in
            ;; a unibyte buffer so Emacs does not ask how to encode raw bytes
            ;; inserted into a multibyte text buffer (e.g. Chinese titles).
            (let ((coding-system-for-write 'no-conversion))
              (with-temp-file temp
                (set-buffer-multibyte nil)
                (insert (json-serialize (vconcat web--history)))))
            (set-file-modes temp #o600)
            (rename-file temp (expand-file-name "history.json" web-data-directory) t))
        (when (file-exists-p temp) (delete-file temp))))))

(defun web-history ()
  "Choose and open a previously visited URL."
  (interactive)
  (web--history-load)
  (unless web--history (user-error "Browser history is empty"))
  (let* ((choices (mapcar (lambda (item)
                            (cons (format "%s  %s" (plist-get item :title)
                                          (plist-get item :url))
                                  (plist-get item :url))) web--history))
         (url (cdr (assoc (completing-read "History: " choices nil t) choices))))
    (if (memq (current-buffer) (web--buffers)) (web-open-url url) (web url))))

(defun web-diagnostics ()
  "Display native browser state and paths for troubleshooting."
  (interactive)
  (let ((page-info (when web--id (web--native-inspect web--id))))
    (with-help-window "*Web diagnostics*"
      (princ (format "Emacs: %s\nModule: %s\nRuntime: %s\nData: %s\nPump: %s\n\n%s\n"
                     emacs-version web-native-module web-runtime-directory web-data-directory
                     (if web--timer "running" "stopped")
                     (if web--initialized (web--native-info) "Not initialized")))
      (when page-info (princ (concat "\nCurrent view: " page-info "\n"))))))

;; Refresh existing browser headers when this file is loaded again.
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (derived-mode-p 'web-mode)
      (setq-local header-line-format web--header-line-format))))
(force-mode-line-update t)

(when (web--buffers)
  (setq web--tabs (web--buffers))
  (web--session-load)
  (web--session-changed))

(provide 'web)
;;; web.el ends here
