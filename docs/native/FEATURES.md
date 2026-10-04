# Нативные возможности — журнал соответствия

Статус «готово» ставится только после проверки. Источник требований: SPEC.md.

| Возможность | Реализация | Проверка |
|---|---|---|
| Локальный каталог / автосохранение / восстановление | в работе | Swift tests |
| Оригиналы 4K / прокси 1080p | в работе | plan + AVFoundation tests |
| Импорт видео, фото, аудио / Share Extension | ожидает | device integration |
| Preview, scrub, timeline, split, trim, reorder | ожидает | XCTest + iPhone |
| Undo / redo / транзакции жестов | в работе | Swift tests |
| Layers / crop / transform / opacity | ожидает | plan + frame comparisons |
| Speed / source time mapping | в работе | Swift + media tests |
| Volume / fades / channels / music | ожидает | audio RMS checks |
| Grade / LUT / effects / transitions | ожидает | frame comparisons |
| Text / keyframes / captions | ожидает | native render tests |
| Retouch / background removal | ожидает | native implementation required |
| Export / progress / cancel / Photos / Share | ожидает | 1080p and 4K device exports |
| Apple / Google / verified email / delete account | ожидает | own API + iOS integration |
| Touch accuracy / smooth timeline / offline use | ожидает | iPhone measurements |

Нельзя объявлять таблицу выполненной по наличию кнопок или успешной компиляции.
