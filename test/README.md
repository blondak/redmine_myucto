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

Samostatné testy běží na Ruby 4.0, ActiveRecord 7.2 a SQLite3. Navíc integrační smoke test ověřuje skutečný start Redmine 6.1 v Dockeru, registraci callbacků, vytvoření času, záložku nastavení, vykreslení formuláře a role administrátor / pouze čtení / správa. Ruby 4 nepoužívejte pro Redmine 6.0; ten podporuje Ruby 3.1–3.3. Nebyla otestována souběžnost nad produkční PostgreSQL/MySQL/MariaDB ani živé API MyÚčta.

Před produkční instalací proveďte na stagingu Redmine 6 s testovací firmou MyÚčta: migraci a start aplikace, nastavení oprávnění, vytvoření/úpravu/smazání času přes web i REST, hromadnou úpravu, přesun měsíce, odmítnutí změny vystavené faktury (včetně konkrétní zprávy při smazání) a obnovu po nedostupném API. Ověřte, že token není ve výpisu chyb ani v logu.

## Skutečný Redmine v jednorázovém kontejneru

Z kořene pluginu spusťte (potřebuje Docker a stažení oficiálního image):

```sh
docker run --rm \
  -e RAILS_ENV=production \
  -e REDMINE_PLUGINS_MIGRATE=1 \
  -e MYUCTO_DISPOSABLE_TEST=1 \
  -v "$PWD:/usr/src/redmine/plugins/redmine_myucto:ro" \
  redmine:6.1 rails runner plugins/redmine_myucto/test/redmine/settings_smoke.rb
```

Test vytváří syntetické projekty, role a uživatele výhradně v dočasné SQLite kontejneru. Nespouštějte ho na produkční databázi. Před opravou registrace v `init.rb` reprodukoval chybějící záložku i pod administrátorem; registrační kód nesmí být v dalším vnořeném `config.to_prepare`, protože Redmine už `init.rb` spouští uvnitř svého callbacku.
