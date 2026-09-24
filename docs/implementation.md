# Реализация Platform V

## Карта файлов

| Файл | Назначение |
| --- | --- |
| [.info.meta.json](../.info.meta.json) | Явный состав импортируемого архива |
| [model.dataspace.xml](../model.dataspace.xml) | Модель sber_npf_pds_contracts, версия 1.1.0-SNAPSHOT |
| [model.graphql-permissions.json](../model.graphql-permissions.json) | Разрешённые именованные операции, полные тела, условия доступа |
| [ac.json](../ac.json) | Роли и scopes |
| [pdsContractApproval.bpmn](../pdsContractApproval.bpmn) | Согласование ПДС |
| [kidOpsStorage.bpmn](../kidOpsStorage.bpmn) | Обработка и хранение КИД ОПС |
| [env.json](../model/graphql/env.json) | Конфигурация GraphQL-окружения ds |
| [lcui/main.json](../lcui/main.json), [routes.json](../lcui/routes.json) | Сохранённые настройки low-code UI |
| [package-platform-v.sh](../scripts/package-platform-v.sh) | Упаковка по манифесту |

## Модель хранения

| Сущность | Поля и связи |
| --- | --- |
| DocumentType | Справочник вида и имени |
| DocumentProcessSettings | Вид, processId, enabled |
| Document | Уникальный documentId, вид, автор, дата, version, changeToken; связи с реквизитами, версиями и командами |
| PdsContract | parent-ссылка document с unique, дата/номер договора, СНИЛС, status |
| KidOps | parent-ссылка document с unique, дата/номер, год подписания, ФИО, СНИЛС, status |
| DocumentVersion | parent document, индекс documentId, version, schemaVersion, JSON attributes/attachments в Text, автор, даты создания и закрытия |
| DocumentCommand | parent document, уникальный commandKey, requestHash, JSON response |
| Attachment | attachmentId, logicalAttachmentId, строковый documentId, имя, MIME, размер, storageReference, version, current, uploadedAt |

DocumentVersion имеет уникальный индекс по document/version. Обратные связи Document задаются mappedBy. Это прикладные снимки, а не встроенная historization DataSpace. Attachment — самостоятельная сущность со строковой ссылкой на владельца; согласованность состава обеспечивает ядро. В модели attachmentId не помечен unique: нельзя описывать его как уже имеющееся ограничение DataSpace.

Статусы ПДС: CREATED, IN_WORK, ON_APPROVAL, NEEDS_REVISION, APPROVED, REJECTED. КИД ОПС: CREATED, IN_WORK, STORED. Они принадлежат реквизитам соответствующего вида, не JSON-снимку версии.

## GraphQL и транзакции

Permissions содержат полные тела операций и требования привилегий. Среди операций — справочники, поиск, создание через BPMN, изменение статусов и команды снимков. Ресурсы Corelia находятся в соседнем corelia/corelia-platform-v/src/main/resources/graphql; независимая фикстура — corelia/corelia-system-tests/src/test/resources/platform-v/allowed-requests.json.

commitDocumentAttributes и commitKidOpsAttributes объединяют сравнение ожидаемого состояния, обновление реквизитов, создание снимка, закрытие предыдущего и запись результата команды. commitDocumentNoChange фиксирует результат без новой версии. commitDocumentFileUpload/Replace/Delete меняют текущий состав и метаданные с проверкой состояния. initializeDocumentVersion создаёт первый снимок.

Пакет хранилища — транзакционная граница. DAM и BPM не включаются в эту транзакцию. Совпадение текстов запросов с фикстурой не доказывает исполнение реальных permissions или генерацию модели SDK.

## Процессы

Process_pds_contract_approval создаёт Document и PdsContract пакетом с ref:createDocument. Пользовательские этапы: взятие оператором, обработка оператором, взятие согласующим и согласование. Процесс управляет статусами и ветвлениями через переменную status, совпадающую с полем документа. Новая версия документа не создаёт новый процесс.

Process_kid_ops_storage получает метаданные первого файла, предварительно загруженного Corelia в DAM. Пакет создания фиксирует Document, KidOps, Attachment и результат команды. Затем оператор берёт документ, работает с ним и отправляет в STORED. Первый снимок инициализирует ядро после появления документа; это отдельная восстанавливаемая операция.

Идентификаторы процессов указаны в DocumentProcessSettings. Изменение processId, переменных или структуры уже исполняемой задачи требует проверки существующих экземпляров, а не только публикации нового BPMN.

## Права

ac.json объявляет app_owner, document_operator, approver. Например, чтение ПДС и Attachment включает approver, тогда как KidOps:read объявлен для app_owner и document_operator. DocumentVersion:commit предоставлен владельцу и оператору. Эти scopes не заменяют проверку текущего статуса и исполнителя в Corelia и условий permissions.

При изменении доступа нужно сверять роль в токене, scope, условия GraphQL, назначение BPM и политику document-service. Не расширять права только ради устранения ошибки интеграции без выяснения её причины.

## Сохранённые legacy-компоненты

LCUI Hosts содержит BFF с devUrl localhost:4000 и pathPrefix /api; routes описывает только ПДС. Это фактическое содержимое поставки, не актуальная схема React → Corelia на /api/core/v1. Файлы входят в манифест и не удалены при документировании: изменение их назначения требует отдельной проверки потребителей.

Справочники DocumentType и DocumentProcessSettings загружаются GraphQL-запросами через конструктор Platform V. Legacy seed-скрипт и его локальные данные удалены.

## Добавление вида

Добавить реквизиты и связь с Document, справочники и нужные операции/права; согласовать политику, адаптер и регистрацию в Corelia и форму React. Общая сущность DocumentVersion используется повторно. Если нужен процесс, добавить BPMN и запись DocumentProcessSettings, включить файл в манифест. Правила ПДС не переносить автоматически на другой вид.
