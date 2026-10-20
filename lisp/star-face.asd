(asdf:defsystem #:star-face
  :description "StarIntel facial-recognition document plugin: native Star-Lang actors"
  :author "starintel-labs"
  :license "AGPL-3.0-only"
  :version "0.1.0"
  :depends-on (#:starlang-runtime #:yason #:ironclad #:babel)
  :serial t
  :components
  ((:module "src"
    :components
    ((:file "packages")
     (:file "documents")
     (:file "insightface")
     (:file "storage")
     (:file "handlers")))))

(asdf:defsystem #:star-face/t
  :description "star-face contract tests on the real deterministic dispatcher"
  :depends-on (#:star-face #:starlang-runtime #:starlang-compiler #:fiveam #:yason)
  :serial t
  :components
  ((:module "t"
    :components
    ((:file "main")))))
