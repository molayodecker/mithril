spec = MithrilWeb.ApiSpec.spec()
File.write!("openapi-export.json", Jason.encode!(spec, pretty: true))
IO.puts("Exported Mithril OpenAPI to openapi-export.json")
