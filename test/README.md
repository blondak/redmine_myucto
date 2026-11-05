# Testy

Z kořene pluginu, v Ruby podporovaném cílovou verzí Redmine:

```sh
BUNDLE_GEMFILE=Gemfile.test bundle install
BUNDLE_GEMFILE=Gemfile.test bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require_relative file }'
```

Testovací Gemfile je oddělený od Redmine a nepřidává závislosti do jeho produkční instalace. Již připravené prostředí s Minitest 5, ActiveRecord 7.2 a SQLite3 může spustit stejný Ruby příkaz přímo.

Chování vyhledávacího výběru firmy (výběr, chyba API a opožděná odpověď po změně URL) ověříte bez dalších balíčků:

```sh
node test/javascript/supplier_picker_test.js
```

Tyto testy používají jednoduchý testovací DOM; nenahrazují ověření vykreslení nabídky v prohlížeči s běžícím Redmine.

- `test/unit`: HTTP kontrakt s řízeným transportem, autentizace, stránkování, timeouty, konflikty, opakování a slučování výkazů.
- `test/integration`: skutečné migrace, modely a transakce ActiveRecord nad dočasnou SQLite v paměti; fronta, přesuny, obnova po ztracené odpovědi, unikátní vazby a callbacky času. `Project` a `TimeEntry` jsou minimální testovací modely, nikoli plná implementace Redmine.

Lokální ověření proběhlo na Ruby 4.0, ActiveRecord 7.2 a SQLite3. **Nejde o ověřený běh celé aplikace Redmine 6**, která zde není nainstalovaná. Ruby 4 nepoužívejte pro Redmine 6.0; ten podporuje Ruby 3.1–3.3. Nebyla otestována souběžnost nad produkční PostgreSQL/MySQL/MariaDB ani živé API MyÚčta.

Před produkční instalací proveďte na stagingu Redmine 6 s testovací firmou MyÚčta: migraci a start aplikace, nastavení oprávnění, vytvoření/úpravu/smazání času přes web i REST, hromadnou úpravu, přesun měsíce, odmítnutí změny vystavené faktury (včetně konkrétní zprávy při smazání) a obnovu po nedostupném API. Ověřte, že token není ve výpisu chyb ani v logu.
