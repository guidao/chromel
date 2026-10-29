;;; gui-hints.el --- Link hints in a real renderer -*- lexical-binding: t; -*-
(require 'web)
(setq web-data-directory (file-name-as-directory (getenv "WEB_TEST_PROFILE")))
(defvar web-test--source nil)
(defvar web-test--child nil)
(defvar web-test--phase 'loading)
(defvar web-test--deadline (+ (float-time) 35))
(defvar web-test--busy nil)

(defun web-test--assert (value description)
  (unless value (error "%s" description)))

(defun web-test--trace (description)
  (write-region (concat description "\n") nil (getenv "WEB_TEST_RESULT") t 'silent))

(defun web-test--finish (success description)
  (let ((trace (when (file-exists-p (getenv "WEB_TEST_RESULT"))
                 (with-temp-buffer (insert-file-contents (getenv "WEB_TEST_RESULT")) (buffer-string)))))
    (with-temp-file (getenv "WEB_TEST_RESULT")
      (insert (or trace "") (if success "PASS: " "FAIL: ") description "\n")))
  (kill-emacs (if success 0 1)))

(defun web-test--overlay-count ()
  (web--eval "JSON.stringify(document.querySelectorAll('[data-emacs-web-hints]').length)"))

(defun web-test--step ()
 (unless web-test--busy
  (let ((web-test--busy t))
   (with-current-buffer (window-buffer (selected-window))
  (condition-case err
      (progn
        (when (> (float-time) web-test--deadline) (error "Hints timed out: %s" web-test--phase))
        (pcase web-test--phase
          ('loading
           (when (equal (buffer-local-value 'web--title web-test--source)
                        (getenv "WEB_TEST_EXPECT_TITLE"))
             (switch-to-buffer web-test--source)
             (delete-other-windows)
             (web--sync)
             (web--command "unfocus")
             (web-test--trace "Inspecting badges")
             (let ((hints (web--eval (format "%s(\"as\",\"inspect\")" (web--hint-script)))))
               (web-test--assert (= 6 (length hints))
                                 (format "Hidden/covered/offscreen link filtering failed: %S" hints))
               (web-test--assert (= 3 (length (plist-get (car hints) :label))) "Expected multiletter labels")
               (web-test--assert (= 1 (web-test--overlay-count)) "Hint badges were not attached")
               (web--eval (web--hint-call "inspect" "filter" "s"))
               (web-test--assert
                (= 2 (web--eval "JSON.stringify(Array.from(document.querySelector('[data-emacs-web-hints]').shadowRoot.children).filter(x=>!x.hidden).length)"))
                "Prefix filtering did not hide unmatched badges")
               (web--eval (web--hint-call "inspect" "clear")))
             (web-test--trace "Cancelling hints")
             ;; Drive the real command's cancellation path.
             (let ((unread-command-events '(7)))
               (condition-case nil (web-follow) (quit nil)))
             (web-test--assert (= 0 (web-test--overlay-count)) "Cancel left hint badges behind")
             (web-test--trace "Opening new buffer by label")
             ;; A completed label opens a new buffer without Return.
             (let ((unread-command-events '(?a ?a ?s)) (web-hint-alphabet "as"))
               (web-follow-new-buffer))
             (setq web-test--phase 'opening)))
          ('opening
           (when (not (eq (window-buffer (selected-window)) web-test--source))
             (setq web-test--child (window-buffer (selected-window)))
             (web-test--assert (not (eq web-test--child web-test--source)) "New-buffer follow reused source")
             (web-test--assert (equal (buffer-local-value 'web--url web-test--source) (getenv "WEB_TEST_URL"))
                               "New-buffer follow navigated the source")
             (setq web-test--phase 'child)))
          ('child
           (when (equal (buffer-local-value 'web--title web-test--child) "hint-target")
             (web-test--assert
              (eq :false (plist-get (json-parse-string (web--native-inspect web--id) :object-type 'plist) :focused))
              "New-buffer hint lost Emacs command focus")
             (web-test--trace "Following in current buffer")
             (kill-buffer web-test--child)
             (switch-to-buffer web-test--source)
             (web--sync)
             (web-test--assert (= 0 (web-test--overlay-count)) "New-buffer follow left badges behind")
             (let ((unread-command-events '(?a ?a ?s)) (web-hint-alphabet "as")) (web-follow))
             (web-test--assert (eq (window-buffer (selected-window)) web-test--source) "Current-page follow made a buffer")
             (setq web-test--phase 'followed)))
          ('followed
           (when (equal (buffer-local-value 'web--title web-test--source) "hint-target")
             (web-test--assert
              (eq :false (plist-get (json-parse-string (web--native-inspect web--id) :object-type 'plist) :focused))
              "Navigation after hint lost Emacs command focus")
             (web-test--assert (= 0 (web-test--overlay-count)) "Navigation left badges behind")
             (let (empty)
               (condition-case nil (web-follow) (user-error (setq empty t)))
               (web-test--assert empty "Empty page did not report no visible links"))
             (web-test--assert (= 0 (web-test--overlay-count)) "Empty page left badges behind")
             (kill-buffer web-test--source)
             (setq web-test--phase 'closing)))
          ('closing
           (when (string-match-p "Browsers including DevTools: 0" (web--native-info))
             (web-test--finish t "Link hints: visibility, shadow DOM, multiletter labels, filtering, cancel, current/new buffer, cleanup")))))
    (error (web-test--finish nil (format "%s (phase %s, buffer %s, selected %s)"
                                        (error-message-string err) web-test--phase
                                        (buffer-name) (buffer-name (window-buffer (selected-window)))))))))))

(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (setq web-test--source (web (getenv "WEB_TEST_URL")))
                     (run-at-time 0.2 0.2 #'web-test--step))
                 (error (web-test--finish nil (error-message-string err))))))
