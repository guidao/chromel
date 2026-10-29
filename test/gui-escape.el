;;; gui-escape.el --- Real Escape routing regression -*- lexical-binding: t; -*-
(require 'web)
(setq web-data-directory (file-name-as-directory (getenv "WEB_TEST_PROFILE")))
(setq ns-use-native-fullscreen nil)
(when (getenv "WEB_TEST_FULLSCREEN")
  (set-frame-parameter nil 'fullscreen 'fullboth))
(defvar web-test--buffer nil)
(defvar web-test--busy nil)
(defvar web-test--deadline (+ (float-time) 35))
(defun web-test--assert (value message) (unless value (error "%s" message)))
(defun web-test--finish (ok text)
  (with-temp-file (getenv "WEB_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun web-test--escape ()
  ;; Feed an actual Cocoa key while Emacs is reading input.  Accept either
  ;; immediate quit or a Control-g key sequence, as normal C-g can do both.
  (let* ((buffer web-test--buffer)
         (inject (run-at-time 0.1 nil (lambda () (with-current-buffer buffer (web--command "test-key" "escape")))))
         (timeout (run-at-time 3 nil (lambda () (setq unread-command-events (list ?z)))))
         (key (unwind-protect
                  (condition-case nil (read-key-sequence "Test Escape") (quit 'quit))
                (cancel-timer inject) (cancel-timer timeout))))
    (web-test--assert (or (eq key 'quit) (equal key (kbd "C-g")))
                      (format "Escape did not become C-g: %S; %s; fullscreen=%S" key (web--native-inspect web--id) (frame-parameter nil 'fullscreen)))))
(defun web-test--exercise ()
  (interactive)
  (condition-case err
      (with-current-buffer web-test--buffer
        (when (> (float-time) web-test--deadline) (error "Escape test timed out"))
        (progn
          (switch-to-buffer web-test--buffer)
          (delete-other-windows)
          (web--sync)
          (web--eval "JSON.stringify((window.escapeCount=0,addEventListener('keydown',e=>{if(e.key==='Escape')escapeCount++}),document.querySelector('input').focus(),true))")
          (web-focus)
          (message "Testing page Escape")
          (web-test--escape)
          (web-test--assert (eq :false (plist-get (json-parse-string (web--native-inspect web--id) :object-type 'plist) :focused)) "Escape left focus in the page")
          (web-test--assert (= 0 (web--eval "JSON.stringify(escapeCount)")) "Escape leaked to the page")
          ;; Now Emacs owns the keyboard: Meow must not override C-g.
          (message "Testing command Escape")
          (when (fboundp 'meow-normal-mode) (meow-normal-mode 1))
          (web-test--escape)
          (when (getenv "WEB_TEST_FULLSCREEN")
            (web-test--assert (eq (frame-parameter nil 'fullscreen) 'fullboth)
                              "Escape exited fullscreen"))
          (kill-buffer web-test--buffer)
          (let ((deadline (+ (float-time) 3)))
            (while (and (< (float-time) deadline) (not (string-match-p "Browsers including DevTools: 0" (web--native-info))))
              (web--tick) (accept-process-output nil 0.02)))
          (web-test--finish t "Cocoa Escape becomes C-g in focused input and Emacs/Meow; no page Escape; fullscreen preserved")))
    (error (web-test--finish nil (error-message-string err)))))
(global-set-key [web-test-run] #'web-test--exercise)
(defun web-test--step ()
  (unless web-test--busy
    (when (with-current-buffer web-test--buffer
            (equal web--title (getenv "WEB_TEST_EXPECT_TITLE")))
      (setq web-test--busy t
            unread-command-events (list 'web-test-run)))))

(run-at-time 1 nil (lambda ()
                     (setq web-test--buffer (web (getenv "WEB_TEST_URL")))
                     (run-at-time 0.2 0.2 #'web-test--step)))
