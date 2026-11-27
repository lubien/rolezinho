# Populates the database with two accounts and a spread of events and groups,
# so every state the UI can be in is reachable without setting it up by hand:
#
#     mix run priv/repo/seeds.exs
#
# Wipes events, groups and users first, so running it twice is safe. Dev and
# PR previews only: it would wipe real accounts anywhere else.

if Mix.env() == :prod, do: raise("seeds wipe every user; refusing to run in prod")

alias Rolezinho.Accounts.User
alias Rolezinho.Event
alias Rolezinho.Events
alias Rolezinho.Group
alias Rolezinho.Groups
alias Rolezinho.Notifications
alias Rolezinho.Repo

Repo.delete_all(Event)
Repo.delete_all(Group)
Repo.delete_all(User)

# Inserted directly rather than through `Accounts.register_user/1`: the short
# `admin`/`user` credentials fail the signup rules (6+ char username, 8+ char
# password), but sign-in only checks the hash, so they still log in.
seed_user = fn username, admin? ->
  %User{}
  |> Ecto.Changeset.change(
    username: username,
    name: String.capitalize(username),
    password_hash: Bcrypt.hash_pwd_salt(username),
    admin: admin?
  )
  |> Repo.insert!()
end

admin = seed_user.("admin", true)
user = seed_user.("user", false)

seed_group = fn attrs, owner ->
  {:ok, group} = Groups.create(attrs, created_by_user_id: owner.id)
  group
end

pelada =
  seed_group.(%{"name" => "Pelada do Bairro", "slug" => "pelada-do-bairro"}, admin)

familia =
  seed_group.(
    %{
      "name" => "Família Souza",
      "slug" => "familia-souza",
      "password" => "SOUZA",
      "visibility" => "hidden"
    },
    admin
  )

trampo =
  seed_group.(
    %{"name" => "Galera do Trampo", "slug" => "galera-do-trampo", "password" => "TRAMPO"},
    user
  )

{:ok, _} = Groups.remember_unlock(user.id, familia.id)
{:ok, _} = Notifications.follow(user, pelada)

# Dates are anchored to today so the listing always has something upcoming,
# and one event in the past to exercise the closed state.
today = Date.utc_today()
in_days = fn days -> today |> Date.add(days) |> Date.to_iso8601() end

# `admin?: true` so the seeded events land on the home page. Without it they
# would all be born hidden, which is right for a real visitor's event but would
# leave a freshly seeded home page empty.
create = fn attrs, owner, opts ->
  opts = Keyword.merge([admin?: true, created_by_user_id: owner.id], opts)
  {:ok, event} = Events.create(attrs, opts)
  event
end

fill = fn event, names ->
  Enum.reduce(names, event, fn {name, paid?}, acc ->
    {:ok, acc} = Events.add_to_main(acc, name, participant_id: "seed-#{:erlang.phash2(name)}")

    if paid? do
      index = Enum.find_index(acc.main_list, &(&1.name == name)) + 1
      {:ok, acc} = Events.toggle_paid_main(acc, index)
      acc
    else
      acc
    end
  end)
end

queue = fn event, names ->
  Enum.reduce(names, event, fn name, acc ->
    {:ok, acc} = Events.add_to_wait(acc, name, participant_id: "seed-w-#{:erlang.phash2(name)}")
    acc
  end)
end

# 1. The everyday case: room left, most people have paid.
create.(
  %{
    "title" => "Vôlei Ver-o-Beach",
    "slug" => "volei-ver-o-beach",
    "category" => "esporte",
    "local" => "Rua Caripunas",
    "date" => in_days.(2),
    "time" => "19:00",
    "price" => "R$ 15",
    "pix_key" => "(91) 98493-3238",
    "pix_key_type" => "phone",
    "description" => "Leva água. Quadra 3.",
    "main_size" => "12",
    "wait_size" => "4"
  },
  admin,
  []
)
|> fill.([
  {"Márcia", true},
  {"Robertinha", false},
  {"Henrique", true},
  {"Yngrid", true},
  {"Matheus", false},
  {"Letícia", true}
])
|> queue.(["Rivanete"])

# 2. Full list with a queue behind it: the join button reads "Entrar na espera".
create.(
  %{
    "title" => "Futevôlei da Praia",
    "slug" => "futevolei-da-praia",
    "category" => "esporte",
    "local" => "Praia do Farol",
    "date" => in_days.(1),
    "time" => "07:00",
    "price" => "20",
    "pix_key" => "52998224725",
    "pix_key_type" => "cpf",
    "main_size" => "4",
    "wait_size" => "3"
  },
  user,
  []
)
|> fill.([{"Diego", true}, {"Gaby", true}, {"Viny", true}, {"Anna Clara", false}])
|> queue.(["Kelvin", "Sofia"])

# 3. Free event: no amount, no Pix, no cash banner anywhere.
create.(
  %{
    "title" => "Roda de Violão",
    "slug" => "roda-de-violao",
    "category" => "social",
    "local" => "Casa do Tiago",
    "date" => in_days.(5),
    "time" => "20:00",
    "description" => "Traga o seu instrumento.",
    "main_size" => "10",
    "wait_size" => "0"
  },
  user,
  []
)
|> fill.([{"Bia", false}, {"Rafa", false}])

# 4. Password-protected: the link alone shows the gate, not the list.
create.(
  %{
    "title" => "Aniversário Surpresa",
    "slug" => "aniversario-surpresa",
    "category" => "social",
    "local" => "Endereço no grupo",
    "date" => in_days.(9),
    "time" => "21:00",
    "price" => "35",
    "pix_key" => "festa@example.com",
    "pix_key_type" => "email",
    "password" => "SURPRESA",
    "description" => "Não conta pra aniversariante.",
    "main_size" => "20",
    "wait_size" => "5"
  },
  admin,
  []
)
|> fill.([{"Camila", true}, {"Vitor", true}, {"Marina", false}])

# 5. Everybody paid: the organizer sees no outstanding banner.
create.(
  %{
    "title" => "Coworking Squad",
    "slug" => "coworking-squad",
    "category" => "coworking",
    "local" => "Working Space Batista Campos",
    "date" => in_days.(3),
    "time" => "09:00",
    "price" => "50",
    "pix_key" => "financeiro@coworkingsquad.com",
    "pix_key_type" => "email",
    "main_size" => "8",
    "wait_size" => "0"
  },
  user,
  []
)
|> fill.([{"Ana Paula", true}, {"Bruno", true}, {"Carla", true}])

# 6. Nobody paid yet, and it is tomorrow: the debt banner at its loudest.
create.(
  %{
    "title" => "Churrasco de Sexta",
    "slug" => "churrasco-de-sexta",
    "category" => "social",
    "local" => "Casa do Lubien",
    "date" => in_days.(1),
    "time" => "18:00",
    "price" => "R$ 25",
    "pix_key" => "123e4567-e12b-12d1-a456-426655440000",
    "pix_key_type" => "random",
    "main_size" => "12",
    "wait_size" => "2"
  },
  admin,
  []
)
|> fill.([{"Pedro", false}, {"Juliana", false}, {"Thiago", false}, {"Larissa", false}])

# 7. Already happened and closed: kept as the group's record, joining is shut.
past =
  create.(
    %{
      "title" => "Beach Tennis de Domingo",
      "slug" => "beach-tennis-de-domingo",
      "category" => "esporte",
      "local" => "Arena Ver-o-Rio",
      "date" => in_days.(-6),
      "time" => "08:00",
      "price" => "18",
      "pix_key" => "(91) 98888-7777",
      "pix_key_type" => "phone",
      "main_size" => "6",
      "wait_size" => "0"
    },
    admin,
    []
  )
  |> fill.([
    {"Gisele", true},
    {"Eduardo", true},
    {"Kelly", true},
    {"Karina", true},
    {"João", true}
  ])

{:ok, _} = Events.set_status(past, :done)

# 8. Not confirmed yet: the organizer is still gauging interest.
maybe =
  create.(
    %{
      "title" => "Trilha no Utinga",
      "slug" => "trilha-no-utinga",
      "category" => "esporte",
      "local" => "Parque do Utinga",
      "date" => in_days.(12),
      "time" => "06:30",
      "description" => "Só rola se juntar 6 pessoas.",
      "main_size" => "15",
      "wait_size" => "0"
    },
    user,
    []
  )
  |> fill.([{"Igor", false}, {"Paula", false}])

{:ok, _} = Events.set_status(maybe, :maybe)

# 9-11. A public group: its events leave the home page, the group card stays.
create.(
  %{
    "title" => "Pelada de Quarta",
    "slug" => "pelada-de-quarta",
    "category" => "esporte",
    "local" => "Campo da Pedreira",
    "date" => in_days.(4),
    "time" => "20:00",
    "price" => "10",
    "pix_key" => "pelada@example.com",
    "pix_key_type" => "email",
    "main_size" => "14",
    "wait_size" => "4"
  },
  admin,
  group_id: pelada.id
)
|> fill.([{"Caio", true}, {"Renan", false}, {"Lucas", true}, {"Fábio", false}])

create.(
  %{
    "title" => "Pelada de Sábado",
    "slug" => "pelada-de-sabado",
    "category" => "esporte",
    "local" => "Campo da Pedreira",
    "date" => in_days.(7),
    "time" => "16:00",
    "price" => "10",
    "pix_key" => "pelada@example.com",
    "pix_key_type" => "email",
    "main_size" => "4",
    "wait_size" => "2"
  },
  user,
  group_id: pelada.id
)
|> fill.([{"Caio", true}, {"Renan", true}, {"Lucas", false}, {"Fábio", false}])
|> queue.(["Otávio", "Wesley"])

pelada_past =
  create.(
    %{
      "title" => "Pelada da Semana Passada",
      "slug" => "pelada-da-semana-passada",
      "category" => "esporte",
      "local" => "Campo da Pedreira",
      "date" => in_days.(-4),
      "time" => "20:00",
      "price" => "10",
      "pix_key" => "pelada@example.com",
      "pix_key_type" => "email",
      "main_size" => "14",
      "wait_size" => "0"
    },
    admin,
    group_id: pelada.id
  )
  |> fill.([{"Caio", true}, {"Renan", true}, {"Lucas", true}])

{:ok, _} = Events.set_status(pelada_past, :done)

# 12. Inside a hidden, password-protected group: the group gate covers it.
# `user` has a saved unlock for the group, so it opens for them signed in.
create.(
  %{
    "title" => "Almoço de Domingo",
    "slug" => "almoco-de-domingo",
    "category" => "social",
    "local" => "Casa da Vó",
    "date" => in_days.(3),
    "time" => "12:00",
    "price" => "30",
    "pix_key" => "(91) 97777-6666",
    "pix_key_type" => "phone",
    "main_size" => "25",
    "wait_size" => "0"
  },
  admin,
  group_id: familia.id
)
|> fill.([{"Tia Cida", true}, {"Primo Beto", false}])

# 13-14. A password-protected group owned by `user`: one event collecting
# payments only, one hidden from the group page while it's being prepared.
happy_hour =
  create.(
    %{
      "title" => "Happy Hour de Novembro",
      "slug" => "happy-hour-de-novembro",
      "category" => "social",
      "local" => "Bar do Parque",
      "date" => in_days.(-2),
      "time" => "18:30",
      "split_method" => "total_split",
      "total" => "240",
      "pix_key" => "trampo@example.com",
      "pix_key_type" => "email",
      "main_size" => "12",
      "wait_size" => "0"
    },
    user,
    group_id: trampo.id
  )
  |> fill.([{"Alice", true}, {"Bernardo", false}, {"Cecília", true}, {"Davi", false}])

{:ok, _} = Events.set_status(happy_hour, :payments_only)

confraternizacao =
  create.(
    %{
      "title" => "Confraternização de Fim de Ano",
      "slug" => "confraternizacao",
      "category" => "social",
      "local" => "A definir",
      "date" => in_days.(25),
      "time" => "19:00",
      "main_size" => "40",
      "wait_size" => "0"
    },
    user,
    group_id: trampo.id
  )

{:ok, _} = Events.set_hidden(confraternizacao, true)

IO.puts("""

Seeded #{Repo.aggregate(User, :count)} users, #{Repo.aggregate(Group, :count)} groups and \
#{Repo.aggregate(Event, :count)} events.

Sign in at /entrar:
  admin / admin   platform admin
  user  / user    regular account

  /r/volei-ver-o-beach          admin  room left, some unpaid
  /r/futevolei-da-praia         user   full, queue behind it
  /r/roda-de-violao             user   free, no Pix
  /r/aniversario-surpresa       admin  password: SURPRESA
  /r/coworking-squad            user   everybody paid
  /r/churrasco-de-sexta         admin  nobody paid, tomorrow
  /r/beach-tennis-de-domingo    admin  closed, in the past
  /r/trilha-no-utinga           user   status "maybe"

  /g/pelada-do-bairro           admin  public, no password; `user` follows it
    /r/pelada-de-quarta         admin  room left
    /r/pelada-de-sabado         user   full, queue behind it
    /r/pelada-da-semana-passada admin  closed, in the past
  /g/familia-souza              admin  hidden, password: SOUZA; `user` has it unlocked
    /r/almoco-de-domingo        admin  gated by the group
  /g/galera-do-trampo           user   public, password: TRAMPO
    /r/happy-hour-de-novembro   user   payments only, total split
    /r/confraternizacao         user   hidden
""")
