# Testy

Z kořene pluginu, v Ruby podporovaném cílovou verzí Redmine:

```sh
BUNDLE_GEMFILE=Gemfile.test bundle install
BUNDLE_GEMFILE=Gemfile.test bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require_relative file }'
```

Testovací Gemfile je oddělený od Redmine a nepřidává závislosti do jeho produkční instalace. Již připravené prostředí s Minitest 5, ActiveRecord/ActiveJob 7.2 a SQLite3 může spustit stejný Ruby příkaz přímo.

Chování vyhledávacího výběru firmy (výběr, chyba API a opožděná odpověď po změně URL) ověříte bez dalších balíčků:

```sh
node test/javascript/supplier_picker_test.js
```

Tyto testy používají jednoduchý testovací DOM; nenahrazují ověření vykreslení nabídky v prohlížeči s běžícím Redmine.

- `test/unit`: HTTP kontrakt s řízeným transportem, autentizace, stránkování, timeouty, konflikty, opakování a slučování výkazů.
- `test/integration`: skutečné migrace, modely a transakce ActiveRecord nad dočasnou SQLite v paměti; fronta, přesuny, obnova po ztracené odpovědi, unikátní vazby a callbacky času. `Project` a `TimeEntry` jsou minimální testovací modely, nikoli plná implementace Redmine.

Samostatné testy používají Ruby 4.0, ActiveRecord 7.2 a SQLite3. Integrační smoke test ověřuje start Redmine 6.1 v Dockeru, registraci callbacků, vytvoření času, záložku nastavení, vykreslení formuláře a role administrátor / pouze čtení / správa. Ruby 4 nepoužívejte pro Redmine 6.0; ten podporuje Ruby 3.1–3.3. Nebyla otestována souběžnost nad produkční PostgreSQL/MySQL/MariaDB ani živé API MyÚčta.

Testy automatického zpracování ověřují commit/rollback, obnovu trvalé fronty, odložené pokusy, pořadí událostí, duplicitní a ztracené joby, chybu plánování a nezávislou kontrolu plánovače. Používají skutečný ActiveJob se serializací, testovací adaptér a ručně řízené hodiny. Testy workeru deterministicky prokládají kroky dvou instancí, včetně souběžného založení měsíční vazby; nejde o zátěžový test databázových zámků. Samostatná rake úloha `redmine:myucto:sync` zůstává pro diagnostiku nebo ruční režim.

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

Skutečný Async adaptér, HTTP zápis, refill bez návštěvy webu, odložený pokus, restart, vypnutí automatiky a Puma cluster se dvěma procesy ověří druhý smoke test:

```sh
docker run --rm \
  -e RAILS_ENV=production \
  -e REDMINE_PLUGINS_MIGRATE=1 \
  -e MYUCTO_DISPOSABLE_TEST=1 \
  -v "$PWD:/usr/src/redmine/plugins/redmine_myucto:ro" \
  redmine:6.1 rails runner --skip-executor plugins/redmine_myucto/test/redmine/background_smoke.rb
```

Tento test uvnitř dočasného kontejneru přepisuje `config/additional_environment.rb` a spouští skutečné webové procesy. Vzdálené volání MyÚčta nahrazuje testovací implementací; ověřuje plánování a SQL frontu, nikoli živé faktury. Oba smoke testy byly ověřeny na Redmine 6.1.6 / Rails 7.2.4 / Ruby 3.4.12.

`background_reload_smoke.rb` samostatně ověřuje úklid plánovače při reloadu konstant skutečným Zeitwerk loaderem. Používá testovací adaptér a náhradu Rails lifecycle hooku; neověřuje reload celého jádra Redmine a nepřistupuje k databázi:

```sh
docker run --rm --entrypoint ruby \
  -v "$PWD:/usr/src/redmine/plugins/redmine_myucto:ro" \
  redmine:6.1 -rbundler/setup plugins/redmine_myucto/test/redmine/background_reload_smoke.rb
```
