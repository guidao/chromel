;;; gui-scroll.el --- Focused iframe and smooth scroll regression -*- lexical-binding: t; -*-
(require 'web)
(setq web-data-directory (file-name-as-directory (getenv "WEB_TEST_PROFILE")))
(defvar web-test--source nil)
(defvar web-test--busy nil)
(defvar web-test--phase 'loading)
(defvar web-test--deadline (+ (float-time) 40))

(defun web-test--assert (value description)
  (unless value (error "%s" description)))
(defun web-test--js (expression)
  (web--eval (concat "JSON.stringify(" expression ")")))
(defun web-test--until (expression description)
  (let ((deadline (+ (float-time) 4)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (eq t (web-test--js expression)))
      (unless done (accept-process-output nil 0.01)))
    (web-test--assert done description)))
(defun web-test--finish (success description)
  (with-temp-file (getenv "WEB_TEST_RESULT")
    (insert (if success "PASS: " "FAIL: ") description "\n"))
  (kill-emacs (if success 0 1)))
(defun web-test--focus (id x y)
  (web-focus)
  (web--command "click" (web--json (list :x x :y y :newBuffer :false)))
  (web-test--until (format "frameState.%s?.focused" id) (concat "Frame did not receive click: " id))
  ;; Same release path used by C-g before pressing j/k in command mode.
  (web--command "unfocus"))

(defun web-test--frame (name)
  (let ((deadline (+ (float-time) 3)) done)
    (while (and (not done) (< (float-time) deadline))
      (web--tick)
      (setq done (equal name (plist-get (json-parse-string (web--native-inspect web--id) :object-type 'plist)
                                       :focusedFrameName)))
      (unless done (accept-process-output nil 0.01)))
    (web-test--assert done (concat "Did not focus frame: " name))
    (web-test--assert
     (eq :false (plist-get (json-parse-string (web--native-inspect web--id) :object-type 'plist) :focused))
     "Returning to parent stole Emacs command focus")))

(defun web-test--scroll-frames ()
  (let ((web-scroll-step 60) (web-scroll-duration 200))
    (dolist (entry '(("same" 80 80) ("cross" 380 80)))
      (apply #'web-test--focus entry)
      ;; Keep native page focus and send an actual Cocoa key, as a user does
      ;; immediately after clicking into an embedded page.  No C-g first.
      (web-focus)
      (web--command "test-key" "j")
      (web-test--until (format "frameState.%s.y===60 && scrollY===0" (car entry))
                       "j did not scroll the focused iframe independently")
      (unless (eq t (web-test--js "matchMedia('(prefers-reduced-motion: reduce)').matches"))
        (web-test--assert (eq t (web-test--js (format "frameState.%s.samples.some(y=>y>0&&y<60)" (car entry))))
                          "Scroll jumped without intermediate animation frames"))
      (let ((current-prefix-arg 3)) (call-interactively (key-binding (kbd "j"))))
      (web-scroll-down)
      (web-scroll-down)
      (web-test--until (format "frameState.%s.y===360" (car entry)) "Repeated scroll distance was lost")
      (web-scroll-up 5)
      (web-test--until (format "frameState.%s.y===60" (car entry)) "Iframe did not prepare for actual k key")
      (web--command "test-key" "k")
      (web-test--until (format "frameState.%s.y===0" (car entry)) "k did not scroll the iframe up"))
    ;; Two frame boundaries, crossing origins in both directions.
    (web-test--focus "nested" 380 140)
    (web-scroll-down 2)
    (web-test--until "frameState.nested.y===120 && frameState.cross.y===0 && frameState.same.y===0 && scrollY===0"
                     "Nested frame scroll affected its ancestors")
    (web-test--assert
     (eq :false (plist-get (json-parse-string (web--native-inspect web--id) :object-type 'plist) :focused))
     "Frame scrolling stole Emacs command focus")
    ;; Return one layer using the actual key binding, without clicking outside.
    (call-interactively (key-binding (kbd "C-c C-p")))
    (web-test--frame "cross")
    (web-scroll-down)
    (web-test--until "frameState.cross.y===60 && frameState.nested.y===120 && scrollY===0"
                     "Parent command did not redirect scrolling by one layer")
    ;; Re-enter the inner frame, then jump directly to the outermost page.
    (web-test--focus "nested" 380 140)
    (web-test--frame "nested")
    (let ((current-prefix-arg '(4))) (call-interactively (key-binding (kbd "C-c C-p"))))
    (web-test--frame "")
    (web-scroll-down)
    (web-test--until "scrollY===60 && frameState.nested.y===120" "Parent frame routing did not recover")
    ;; Calling parent on the top-level page is harmless.
    (web-focus-parent-frame)
    (web-test--frame "")
    (let ((web-scroll-duration 600))
      (web-scroll-down 2)
      (web-test--until "scrollY>60" "Smooth scroll did not begin")
      (web-scroll-up 6)
      (web-test--until "scrollY===0" "Direction reversal retained the old target")
      (web-scroll-down 10)
      (web-test--until "scrollY>0" "Cancellation test did not start")
      (let ((position (web-test--js "(dispatchEvent(new WheelEvent('wheel')),scrollY)")))
        (accept-process-output nil 0.2)
        (web-test--assert (= position (web-test--js "scrollY")) "Wheel input did not cancel animation")))
    (let* ((position (web-test--js "scrollY")) (web-scroll-duration 0))
      (web-scroll-down 2)
      (web-test--until (format "scrollY===%s" (+ position 120)) "Instant mode failed"))))

(defun web-test--step ()
  (unless web-test--busy
    (let ((web-test--busy t))
      (with-current-buffer (if (buffer-live-p web-test--source) web-test--source (current-buffer))
        (condition-case err
            (progn
              (when (> (float-time) web-test--deadline) (error "Scroll test timed out"))
              (pcase web-test--phase
                ('loading
                 (when (equal web--title "scroll-ready")
                   (switch-to-buffer web-test--source)
                   (delete-other-windows)
                   (web--sync)
                   (web-test--until "Boolean(frameState.same && frameState.cross && frameState.nested)" "Frame fixtures did not load")
                   (web-test--scroll-frames)
                   (kill-buffer web-test--source)
                   (setq web-test--phase 'closing)))
                ('closing
                 (when (string-match-p "Browsers including DevTools: 0" (web--native-info))
                   (web-test--finish t "Scrolling: same/cross-origin nested focus, keyboard parent/root return with Meow, smooth samples, repeated distance, reversal, wheel cancellation, instant mode")))))
          (error (web-test--finish nil (error-message-string err))))))))

(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (set-frame-size nil 1100 750 t)
                     (setq web-test--source (web (getenv "WEB_TEST_URL")))
                     (run-at-time 0.2 0.2 #'web-test--step))
                 (error (web-test--finish nil (error-message-string err))))))
