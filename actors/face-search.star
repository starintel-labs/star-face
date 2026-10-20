(actor face-search
  (:runtime native
   :service-uri "star://starface:localhost:face-search"
   :accepts (org.starintel/star-face@1/search-request)
   :produces (org.starintel/star-face@1/search-reply)
   :handler star-face/face-search-handler
   :restart permanent
   :mailbox (bounded 128)
   :metadata ((domain "starface") (role "db-search"))))
