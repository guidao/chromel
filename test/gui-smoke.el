;;; gui-smoke.el --- Run in an isolated GUI Emacs -*- lexical-binding: t; -*-
(require 'web)
(setq web-data-directory (file-name-as-directory (getenv "WEB_TEST_PROFILE")))
(defvar web-test--buffer nil)
(defvar web-test--original-frame nil)
(defvar web-test--second-frame nil)
(defvar web-test--deadline (+ (float-time) 35))
(defvar web-test--phase 'loading)

(defun web-test--finish (success description)
  (with-temp-file (getenv "WEB_TEST_RESULT")
    (insert (if success "PASS: " "FAIL: ") description "\n"))
  (kill-emacs (if success 0 1)))

(defun web-test--assert (value message)
  (unless value (error "%s" message)))

(defun web-test--step ()
  (condition-case err
      (progn
        (when (> (float-time) web-test--deadline)
          (error "Timed out in phase %s" web-test--phase))
        (pcase web-test--phase
          ('loading
           (when (with-current-buffer web-test--buffer
                   (equal web--title (getenv "WEB_TEST_EXPECT_TITLE")))
             (web-test--assert web--timer "CEF pump stopped")
             (web-test--assert (eq (window-buffer (selected-window)) web-test--buffer)
                               "Opening a page did not select its Emacs window")
             (web-test--assert
              (eq t (plist-get
                     (json-parse-string
                      (web--native-inspect (buffer-local-value 'web--id web-test--buffer))
                      :object-type 'plist)
                     :focused))
              "New page did not receive keyboard focus automatically")
             (delete-other-windows)
             (switch-to-buffer (get-buffer-create "*Web smoke sibling*"))
             (let ((right (split-window-right)))
               (set-window-buffer right web-test--buffer)
               (select-window right))
             (web--sync)
             (web-test--assert (eq web--window (selected-window)) "Wrong split selected")
             (let* ((actual (json-parse-string (web--native-inspect web--id) :object-type 'plist))
                    (edges (window-inside-pixel-edges)))
               (web-test--assert (and (= (plist-get actual :x) (nth 0 edges))
                                      (= (plist-get actual :y) (nth 1 edges))
                                      (= (plist-get actual :width) (- (nth 2 edges) (nth 0 edges)))
                                      (= (plist-get actual :height) (- (nth 3 edges) (nth 1 edges))))
                                 "Native Cocoa geometry disagrees with Emacs split"))
             (web-focus)
             (web--release-focus)
             (web-test--assert
              (eq :false (plist-get (json-parse-string (web--native-inspect web--id)
                                                     :object-type 'plist) :focused))
              "Focus did not return to Emacs")
             (setq web-test--second-frame (make-frame '((name . "Web smoke second"))))
             (select-frame-set-input-focus web-test--second-frame)
             (switch-to-buffer web-test--buffer)
             (web--sync)
             (setq web-test--phase 'reparented)))
          ('reparented
           (web-test--assert (eq (window-frame web--window) web-test--second-frame)
                             "View did not follow its buffer to the second frame")
           (delete-frame web-test--second-frame)
           (select-frame-set-input-focus web-test--original-frame)
           (switch-to-buffer web-test--buffer)
           (web--sync)
           (kill-buffer web-test--buffer)
           (setq web-test--phase 'closing))
          ('closing
           (when (string-match-p "Browsers including DevTools: 0" (web--native-info))
             (web-test--assert (frame-live-p web-test--original-frame) "Host frame was closed")
             (web-test--finish t "GUI Emacs renderer, native geometry, focus API, two frames, close")))))
    (error (web-test--finish nil (error-message-string err)))))

(run-at-time
 1 nil
 (lambda ()
   (condition-case err
       (progn
         (setq web-test--original-frame (selected-frame))
         (setq web-test--buffer
               (web (getenv "WEB_TEST_URL")))
         (run-at-time 0.2 0.2 #'web-test--step))
     (error (web-test--finish nil (error-message-string err))))))
