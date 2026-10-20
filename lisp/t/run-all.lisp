(require :asdf)

(defparameter *star-lang-src*
  (or (uiop:getenv "STAR_LANG_SRC")
      (error "STAR_LANG_SRC must point at the star-lang source tree.")))

(unless (find-package "STAR-LANG.API")
  (load (merge-pathnames "prototype/star-lang-api.lisp"
                         (pathname (concatenate 'string *star-lang-src* "/")))))

(asdf:initialize-source-registry)
(asdf:load-system :star-face/t)

(let ((status (star-face/t:run-all)))
  (format t "~&star-face test suite: ~A~%" status)
  (uiop:quit (if status 0 1)))
