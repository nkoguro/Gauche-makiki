;;;
;;;   Copyright (c) 2023 Shiro Kawai  <shiro@acm.org>
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;
;;;    1. Redistributions of source code must retain the above copyright
;;;       notice, this list of conditions and the following disclaimer.
;;;
;;;    2. Redistributions in binary form must reproduce the above copyright
;;;       notice, this list of conditions and the following disclaimer in the
;;;       documentation and/or other materials provided with the distribution.
;;;
;;;    3. Neither the name of the authors nor the names of its contributors
;;;       may be used to endorse or promote products derived from this
;;;       software without specific prior written permission.
;;;
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;; EXPERIMENTAL

;; Load and run makiki service in subthread for development
(define-module makiki.dev
  (use gauche.threads)
  (use makiki)
  (use util.match)
  (export start-server! stop-server!))
(select-module makiki.dev)

;; Those APIs are supposed to be called interactively in REPL, so
;; we don't worry much about thread safety.

(define *server-file* #f)
(define *server-thread* #f)
(define *watched-file* #f)
(define *watcher-thread* #f)

;; A module where the script is loaded.
;; We use named module, so that the user can switch into this module in REPL.
(define-module makiki.user)
(define *server-module* (find-module 'makiki.user))

;; a hidden parameter to stop the server loop
(define dev-cch (with-module makiki dev-control-channel))

;; API
(define (start-server! :optional (path *server-file*))
  (unless path
    (error "Server file path rquired for the first call."))
  (set! *server-file* path)
  ;; Kludge - clear the existing handlers.  This isn't a public API.
  ((with-module makiki clear-handlers!))
  (set! *server-file*
        (%load (sys-normalize-pathname path :absolute #t :expand #t)
               :environment *server-module*))
  (unless (and (thread? *server-thread*)
               (not (eq? (thread-state *server-thread*) 'terminated)))
    (dev-cch (make-server-control-channel))
    (set! *server-thread*
          (thread-start!
           (make-thread (cut %run-server! *server-module* path)))))
  (unless (and (equal? *watched-file* *server-file*)
               (thread? *watcher-thread*)
               (not (eq? (thread-state *watcher-thread*) 'terminated)))
    (when *watcher-thread*
      (let1 t *watcher-thread*
        (set! *watcher-thread* #f)
        (thread-join! t)))
    (set! *watched-file* *server-file*)
    (set! *watcher-thread* ($ %make-file-watcher *watched-file*
                              (^[] (start-server! *watched-file*)))))
  *server-thread*)

;; Called in a separate thread.  Run 'dev-main if it exists; otherwise,
;; run 'main'.
(define (%run-server! mod server-file)
  (guard (e [else
             (report-error e)
             #f])
    (cond [(global-variable-ref mod 'dev-main #f)
           => (^[dev-main] (dev-main `(,server-file)))]
          [(global-variable-ref mod 'main #f)
           => (^[main] (main `(,server-file)))]
          [else
           (format (current-error-port)
                   "Can't find 'dev-main' nor 'main' in the server script: ~s\n"
                   server-file)
           #f])))

;; Watch file updates by polling.
;; TRANSIENNT: Once file.event module is available in Gauche, rewrite this.
(define (%make-file-watcher server-file thunk)
  (let1 mtime (sys-stat->mtime (sys-stat server-file))
    ($ thread-start! $ make-thread
       (rec (loop)
         (sys-nanosleep #e5e8)
         (let1 mtime2 (sys-stat->mtime (sys-stat server-file))
           (unless (eqv? mtime mtime2)
             (set! mtime mtime2)
             (format (current-error-port) "~%Reloading ~s..." server-file)
             (guard (e [else (report-error e)])
               (thunk))
             (fresh-line (current-error-port)))
           (loop))))))

;; API
(define (stop-server!)
  (when *server-thread*
    (terminate-server-loop (dev-cch) 0)
    (sys-nanosleep #e1e8)               ;for now; better to handshake
    (%shutdown-server! *server-module*)
    (dev-cch #f)
    (thread-terminate! *server-thread*)
    (set! *server-thread* #f))
  #t)

(define (%shutdown-server! mod)
  (cond [(global-variable-ref mod 'dev-shutdown #f)
         => (^[dev-shutdown] (dev-shutdown))]
        [else #f]))


;; From Gauche 0.9.13, 'load' returns the actual file name that's loaded.
;; To run Makiki with Gauche 0.9.12 or before, we emulate that load.
(define (%load path :key environment)
  (match ((with-module gauche.internal find-load-file)
          path *load-path* *load-suffixes*
          :error-if-not-found #t :allow-archive #f)
    [(found _) (and (load found :environment environment) found)]))
