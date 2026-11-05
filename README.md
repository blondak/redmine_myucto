# Redmine MyÚčto

Licence: [MIT](LICENSE).

Plugin pro Redmine 6, který přenáší nové časové záznamy do měsíčních výkazů práce u konceptů faktur v [MyÚčtu](https://github.com/radekhulan/myucto/). Nemění server MyÚčta a faktury nevystavuje.

## Instalace

1. Vložte tento adresář do `plugins/redmine_myucto` v instalaci Redmine 6. Použijte Ruby podporované vaší verzí Redmine (Redmine 6.0: Ruby 3.1–3.3).
2. Nastavte `MYUCTO_API_TOKEN` v prostředí každého webového kontejneru Redmine. Token musí mít oprávnění `read_write`, čtení odběratelů a přístup k fakturám/výkazům příslušné firmy. Token se neukládá do databáze pluginu. Po změně prostředí restartujte nebo znovu vytvořte webové kontejnery.
3. Z kořene Redmine spusťte migraci:

   ```sh
   bundle exec rake redmine:plugins:migrate NAME=redmine_myucto RAILS_ENV=production
   ```

4. V **Administrace → Pluginy → Redmine MyÚčto → Nastavení** vyplňte URL instance, klikněte na **Načíst firmy** a vyberte fakturující firmu podle názvu nebo ID. Pod výběrem se zobrazí její název, IČO a DIČ. URL může obsahovat instalační podadresář nebo končit `/api/v1`. Nastavení uložte a otestujte připojení. Pro vzdálené spojení použijte HTTPS.
5. V projektu zapněte modul **MyÚčto**, rolím přidělte oprávnění pro zobrazení/správu integrace a v **Nastavení projektu → MyÚčto** vyberte klienta faktury (odběratele), povolené uživatele a zapněte synchronizaci. Projektová záložka **MyÚčto** slouží pro přehled faktur a synchronizace.
6. Restartujte webové kontejnery Redmine. Při aktualizaci z verze bez automatického zpracování to stačí; nová migrace databáze není potřeba.

Synchronizace běží uvnitř každého webového procesu přes vyhrazený ActiveJob Async adapter s jedním vláknem na PID. Nepotřebuje cron, Redis ani samostatnou službu workeru. Fronta outboxu je uložena v databázi: změna ji probudí po potvrzení transakce a na startu serveru se čekající práce načte znovu. Periodická kontrola běží každých 60 sekund i bez příchozích webových požadavků; respektuje `available_at` a hotové události znovu nezpracovává. Tento adaptér se nevztahuje na ostatní ActiveJob úlohy Redmine, například e-mail.

Každý webový PID může pro synchronizaci potřebovat jedno další databázové spojení z poolu. Produkční souběžnost vyžaduje PostgreSQL, MySQL nebo MariaDB se zámky řádků. SQLite je určena pro vývoj a testy. Oficiální Docker image s `rails server` i Puma cluster spouštějí synchronizaci při startu, bez návštěvy webu. Při jiném Rack serveru je zálohou první požadavek v daném procesu; pro okamžitý start bez provozu lze z jeho hooku po dokončení bootu každého workeru zavolat `Myucto::Background.start!`. Rake úlohy a Rails runner automatickou synchronizaci nespouštějí.

Volitelně lze automatické zpracování vypnout nastavením `MYUCTO_AUTO_SYNC=0` ve **všech** webových kontejnerech a jejich znovuvytvořením. To je určeno například pro ruční obnovu. Proměnnou předejte do kontejneru v `environment:` (samotný řádek v `.env` nestačí). Po skončení hodnotu odstraňte a kontejnery opět znovu vytvořte. Při vypnuté automatice lze přes UI opravit vazby a zařadit události; přenos pak spustíte ručně úlohou `bundle exec rake redmine:myucto:sync RAILS_ENV=production` nebo znovuzapnutím automatiky. Samotné vypnutí synchronizace projektu nezastaví události, které už byly zařazeny. Pro ruční rake úlohu zůstává výchozí limit 100 událostí, nastavitelný proměnnou `LIMIT`.

## Chování

- Jedna instance MyÚčta, jedna fakturující firma a jedna instance Redmine. Každý projekt a měsíc podle data práce `spent_on` má vlastní vazbu na koncept faktury.
- Přenášejí se **nově založené** časy uživatelů vybraných v nastavení konkrétního projektu. Rozhoduje `time_entry.user_id` (uživatel vykázaného času), nikoli autor záznamu. Prázdný seznam znamená, že se žádné nové časy nepřenášejí. Odebrání uživatele nezastaví aktualizace již propojených časů. Dřívější nepropojené časy se neimportují ani při pozdější úpravě. Vypnutí integrace zastaví přidávání nových časů; již zařazené/propojené časy se dokončí a zůstávají chráněné.
- Nový koncept nemá fakturační položky. Data dokladu, měnu a splatnost doplní MyÚčto podle svých výchozích hodnot. Období práce je v názvu výkazu; při vystavení si zkontrolujte skutečná data dokladu.
- Řádek obsahuje datum práce, hodiny a popis `#číslo Název úkolu — komentář [TE#123]`. Bez úkolu se použije komentář, případně aktivita. Změna názvu úkolu sama historický výkaz nepřepisuje.
- Hodiny se pro databázi MyÚčta zaokrouhlují na dvě desetinná místa. Zapojené časy musí mít alespoň 0,01 h; nulu plugin odmítne s vysvětlením.
- Nový řádek má sazbu nula. Ceny a fakturační položky řešíte v MyÚčtu; plugin zachovává ručně nastavenou sazbu vlastního řádku, včetně přesunu.
- Ruční řádky a materiál zachovává. Značka `[TE#…]` je rezervována pro plugin; nemažte ji ani nekopírujte. Ručně upravené datum, hodiny či popis propojeného řádku, nejasná nebo chybějící značka vedou ke konfliktu. Již provedený zápis/smazání při opakování rozpozná jako dokončený.
- Smazání času odstraní řádek, přesun mezi měsíci/projekty jej přesune do odpovídajícího výkazu. Prázdné koncepty zůstávají. Cílový projekt musí mít nastavenou integraci.
- Změna odběratele projektu nemění existující měsíční vazby. Změna URL nebo firmy v globálním nastavení zablokuje staré vazby; nejde o automatickou migraci do jiné instance.

## Odmítnutí změn a konflikty

Před změnou nebo smazáním propojeného času plugin ověří, že dotčené faktury jsou neuzamčené koncepty. Pokud je faktura vystavená, uzamčená nebo API nedostupné, změnu odmítne s důvodem. Kontrola platí i pro běžné REST a hromadné operace Redmine. Přímé databázové zásahy a cizí pluginy obcházející modelové callbacky nejsou podporované.

API MyÚčta ukládá celý pracovní výkaz a neposkytuje podmíněný zápis podle verze. Kontroly před/po zápisu a zámky mezi webovými procesy nemohou zaručit ochranu před souběžnou ruční úpravou v MyÚčtu. Během synchronizace stejný výkaz ručně neupravujte; zjištěné rozdíly se zobrazí jako konflikt. Stejná mezera existuje při souběžném vystavení faktury a změně času.

## Fronta a obnova

Projektová záložka zobrazuje vazby na faktury, odkazy a posledních 100 událostí. Přechodné chyby mají prodlužující se interval opakování podle `available_at`, nejvýše osm pokusů. Události stejného času se nepředbíhají; chyba jednoho času neblokuje ostatní časy. Tlačítko **Opakovat chybné události** znovu zařadí chyby a probudí zpracování na pozadí, pokud je automatika zapnutá.

- **Chyba:** po odstranění příčiny použijte opakování na stránce projektu.
- **Konflikt:** zkontrolujte fakturu a porovnejte ji s Redmine. Obnovení konfliktní události vyžaduje administrátora a potvrzení; samo nepřepisuje konfliktní ruční změny.
- **Zpracovává se po pádu webového procesu:** přes administrační ovládání projektu obnovte událost až po ověření, že původní proces neběží a vzdálený stav je známý. Před ruční obnovou vypněte automatiku proměnnou `MYUCTO_AUTO_SYNC=0` ve všech webových kontejnerech a znovu je vytvořte. Událost lze obnovit také příkazem:

  ```sh
  bundle exec rake redmine:myucto:recover_event EVENT_ID=123 CONFIRM=yes RAILS_ENV=production
  ```

- **Neověřené založení konceptu (`creating`/`uncertain`):** při `creating` další události omezeně čekají, zda původní proces dokončí založení a uloží ID; samy nový POST neodesílají. Stav `uncertain` ani konflikt se automaticky neopakuje. Po timeoutu může faktura existovat: při ručním zásahu vypněte automatiku, vyhledejte ji v MyÚčtu a administrátorským formulářem v projektu připojte její ID. Plugin ověří odběratele, stav a unikátnost vazby. Poté samostatně obnovte událost.

Nejasný výsledek vytvoření neřešte časovým resetem ani slepým opakováním požadavku. Stav ověřte v MyÚčtu a použijte administrační postup pro připojení již existující faktury nebo ruční obnovu události. Tím se zabrání duplicitnímu konceptu.

Pouze pokud jste ověřili, že původní požadavek **žádnou fakturu nevytvořil**, můžete při vypnutém zpracování povolit nový pokus:

```sh
bundle exec rake redmine:myucto:reset_creation BINDING_ID=123 CONFIRM=remote_absence_verified RAILS_ENV=production
```

Následně samostatně obnovte událost. Tento reset není běžné opakování; nesprávné použití může založit duplicitní fakturu.

## Testy a odinstalace

Postup a rozsah ověření jsou v [test/README.md](test/README.md). Testy používají syntetická data; nevystavují skutečné faktury.

Před odinstalací vypněte automatiku pomocí `MYUCTO_AUTO_SYNC=0`, restartujte webové procesy a zálohujte databázi Redmine. Smazání tabulek pluginu zničí vazby i historii synchronizace. Případný rollback provádějte přes migrační nástroje Redmine, nikoli ručním mazáním tabulek za běhu.

## Práva a viditelnost

Modul musí být zapnutý v projektu. Oprávnění se přidělují v **Administrace → Role a oprávnění → MyÚčto**:

- **Zobrazit synchronizaci MyÚčto** (`view_myucto`): projektová záložka, vazby na faktury a stav událostí celého projektu.
- **Spravovat synchronizaci MyÚčto** (`manage_myucto`): navíc **Nastavení projektu → MyÚčto**, výběr klienta a opakování běžných chyb. Pro tuto záložku není potřeba přidělovat obecné právo upravovat projekt.
- **Administrátor Redmine**: globální URL, fakturující firma, test API a ruční obnova nejasného založení faktury či konfliktů.

Přístup nevzniká samotným členstvím v projektu. Pokud právo přidělíte roli Nečlen nebo Anonymní, u veřejných projektů se uplatní také tato role; pro neveřejná fakturační data jim je nepřidělujte. Přehled MyÚčta nefiltruje události podle vlastníka času — právo zobrazení je pro celý projekt. Seznam povolených uživatelů určuje pouze přenos nových časů; nepřiděluje jim oprávnění vidět modul nebo měnit nastavení.

## Přechod na výběr uživatelů a přenos starších časů

Po aktualizaci spusťte pluginovou migraci uvedenou v instalaci, pokud ji daná verze vyžaduje, a restartujte webové kontejnery. Nový seznam uživatelů je zpočátku prázdný **i u dosavadních projektů**: v **Nastavení projektu → MyÚčto** proto vyberte členy, jejichž nové časy chcete přenášet. Již existující fronta a vazby se zachovají.

Staré záznamy nemažte ani nezadávejte znovu. Administrátor na stránce **Projekt → MyÚčto → Přenos existujícího časového záznamu** zadá ID času z tohoto projektu a stiskne **Zařadit k synchronizaci**. Akce zachová původní záznam i datum práce a zařadí jej do běžné fronty pro příslušný měsíc. Respektuje zapnutí integrace a seznam povolených uživatelů; nepřenáší automaticky celou historii.

Opakované zadání stejného ID už propojený/zařazený čas nepřidá podruhé. Jeho případné chyby řešte přes běžný přehled a obnovu událostí. Pokud je měsíční faktura již vystavená nebo uzamčená, synchronizace záznam označí jako konflikt a fakturu nezmění. Ručně založené faktury se automaticky nevyhledávají ani nepřebírají.
