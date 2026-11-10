;;; gui-escape.el --- Real Escape routing regression -*- lexical-binding: t; -*-
(require 'chromel)
(when (require 'meow nil t)
  (meow-global-mode 1))
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(setq ns-use-native-fullscreen nil)
(when (getenv "CHROMEL_TEST_FULLSCREEN")
  (set-frame-parameter nil 'fullscreen 'fullboth))
(defvar chromel-test--buffer nil)
(defvar chromel-test--busy nil)
(defvar chromel-test--deadline (+ (float-time) 35))
(defun chromel-test--assert (value message) (unless value (error "%s" message)))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun chromel-test--escape (&optional passthrough close-browser)
  ;; Feed an actual Cocoa key while Emacs is reading input.  Accept either
  ;; immediate quit or a Control-g key sequence, as normal C-g can do both.
  (let* ((buffer chromel-test--buffer)
         (inject (run-at-time 0.1 nil
                              (lambda ()
                                (with-current-buffer buffer
                                  (chromel--command "test-key" "escape"))
                                ;; The posted Cocoa events are dispatched after
                                ;; the last browser buffer has been killed.
                                (when close-browser (kill-buffer buffer)))))
         (timeout (run-at-time 3 nil (lambda () (setq unread-command-events (list ?z)))))
         (key (unwind-protect
                  (condition-case nil (read-key-sequence "Test Escape") (quit 'quit))
                (cancel-timer inject) (cancel-timer timeout))))
    (chromel-test--assert (if passthrough
                              (equal key [escape])
                            (or (eq key 'quit) (equal key (kbd "C-g"))))
                         (format "Unexpected Escape routing (passthrough=%S): %S; buffer=%S; fullscreen=%S"
                                 passthrough key (buffer-name) (frame-parameter nil 'fullscreen)))
    key))

(defun chromel-test--other-buffer-escape (&optional keep-visible close-browser)
  (let ((buffer (generate-new-buffer " *chromel-escape-other*")))
    (unwind-protect
        (save-window-excursion
          (when keep-visible (select-window (split-window-right)))
          (switch-to-buffer buffer)
          (text-mode)
          (if (fboundp 'meow-mode)
              (progn (meow-mode 1) (meow-insert-mode 1))
            (local-set-key [escape] #'ignore))
          (chromel--sync)
          (let ((key (chromel-test--escape t close-browser)))
            (when (bound-and-true-p meow-mode)
              (call-interactively (key-binding key))
              (chromel-test--assert (meow-normal-mode-p)
                                    "Escape did not exit Meow insert state"))))
      (kill-buffer buffer)
      (chromel--sync))))
(defun chromel-test--exercise ()
  (interactive)
  (condition-case err
      (with-current-buffer chromel-test--buffer
        (when (> (float-time) chromel-test--deadline) (error "Escape test timed out"))
        ;; Isolate Cocoa key routing from the periodic CEF pump, which can
        ;; consume posted input outside Emacs's read-key-sequence.  Page
        ;; evaluation and the close wait below still pump CEF explicitly.
        (cancel-timer chromel--timer)
        (setq chromel--timer nil)
        (progn
          (switch-to-buffer chromel-test--buffer)
          (delete-other-windows)
          (chromel--sync)
          (chromel--eval "JSON.stringify((window.escapeCount=0,addEventListener('keydown',e=>{if(e.key==='Escape')escapeCount++}),document.querySelector('input').focus(),true))")
          (chromel-focus)
          (message "Testing page Escape")
          (chromel-test--escape)
          (chromel-test--assert (eq :false (plist-get (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist) :focused)) "Escape left focus in the page")
          (chromel-test--assert (= 0 (chromel--eval "JSON.stringify(escapeCount)")) "Escape leaked to the page")
          ;; Now Emacs owns the keyboard: Meow must not override C-g.
          (message "Testing command Escape")
          (when (fboundp 'meow-normal-mode) (meow-normal-mode 1))
          (chromel-test--escape)
          (message "Testing Escape after switching away from a focused page")
          (chromel-focus)
          (chromel-test--other-buffer-escape t)
          (chromel-focus)
          (chromel-test--other-buffer-escape)
          (chromel-focus)
          (chromel-test--other-buffer-escape nil t)
          (when (getenv "CHROMEL_TEST_FULLSCREEN")
            (chromel-test--assert (eq (frame-parameter nil 'fullscreen) 'fullboth)
                              "Escape exited fullscreen"))
          (let ((deadline (+ (float-time) 3)))
            (while (and (< (float-time) deadline) (not (string-match-p "Browsers including DevTools: 0" (chromel--native-info))))
              (chromel--tick) (accept-process-output nil 0.02)))
          (chromel-test--finish t "Browser Escape becomes C-g; other buffers retain Escape and exit Meow insert with the page visible, hidden or closed; fullscreen preserved")))
    (error (chromel-test--finish nil (error-message-string err)))))
(global-set-key [chromel-test-run] #'chromel-test--exercise)
(defun chromel-test--step ()
  (unless chromel-test--busy
    (when (with-current-buffer chromel-test--buffer
            (equal chromel--title (getenv "CHROMEL_TEST_EXPECT_TITLE")))
      (setq chromel-test--busy t
            unread-command-events (list 'chromel-test-run)))))

(run-at-time 1 nil (lambda ()
                     (setq chromel-test--buffer (chromel (getenv "CHROMEL_TEST_URL")))
                     (run-at-time 0.2 0.2 #'chromel-test--step)))
