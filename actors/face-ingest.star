(actor face-ingest
  (:runtime native
   :service-uri "star://starface:localhost:face-ingest"
   :accepts (org.starintel/star-face@1/face-result)
   :produces (org.starintel/star-face@1/ingest-result)
   :handler star-face/face-ingest-handler
   :restart permanent
   :mailbox (bounded 128)
   :metadata ((domain "starface") (role "document-plugin"))))
