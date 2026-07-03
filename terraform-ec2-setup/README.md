# Terraform EC2 Setup — Full Guide (Explained Simply)

This guide explains **everything** in this project like you're explaining it to a
middle schooler. No confusing jargon without an explanation first!

---

## 1. What is this project actually doing?

Imagine you want to rent a computer from Amazon (this is called an **EC2 instance**)
that lives in Amazon's data center instead of your house. Normally you'd have to
click around a website, choose settings, and press buttons to create it.

**Terraform** is a tool that lets you write down what you want in a text file, and
then it builds it for you automatically — like a recipe for a robot chef. Instead
of a robot chef, it's a robot cloud-computer-builder.

This project has 4 "recipe" files that work together, plus this README file that
explains it all.

```
terraform-ec2-setup/
├── main.tf         <- The main recipe: "build me a computer"
├── providers.tf    <- Tells Terraform which company (AWS) and how to talk to it
├── variables.tf    <- A list of settings you can easily change
├── outputs.tf      <- What info to show you after it's done
└── README.md       <- You are here!
```

---

## 2. What is AWS?

**AWS (Amazon Web Services)** is Amazon's cloud computing business. Instead of
buying your own physical computer, you "rent" one from Amazon's giant warehouses
full of servers. You only pay for what you use.

---

## 3. Line-by-Line: `providers.tf`

This file tells Terraform: "Hey, we're going to be working with AWS, here's the
version of the AWS toolkit to use, and here's the version of Terraform itself
needed to run this."

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.2.0"
}
```

- `terraform { }` — This whole block is Terraform talking about itself: "here are
  my own settings."
- `required_providers { }` — A **provider** is a plugin that lets Terraform talk to
  a specific company's cloud (AWS, Google Cloud, Microsoft Azure, etc). We're only
  using AWS here.
- `source = "hashicorp/aws"` — This says "download the official AWS plugin made by
  HashiCorp" (HashiCorp is the company that makes Terraform).
- `version = "~> 5.0"` — This means "use any version that starts with 5, like 5.1,
  5.2, 5.99 — but don't jump to version 6.0." The `~>` symbol means "allow small
  updates, but not big ones that might break things."
- `required_version = ">= 1.2.0"` — This means "you must be using Terraform version
  1.2.0 or newer to run this project," kind of like a game requiring a minimum
  version of an app to run.

```hcl
provider "aws" {
  region = var.aws_region
}
```

- `provider "aws" { }` — This actually turns on and configures the AWS plugin.
- `region = var.aws_region` — A **region** is a physical location of Amazon's data
  centers (like a city). This line says "use whatever region is set in the
  variables file" instead of hardcoding it here. Right now that default is
  `us-east-1`, which is a data center located in Northern Virginia — geographically
  one of the closer AWS regions to Alabama, which usually means faster/lower-lag
  connections.

---

## 4. Line-by-Line: `variables.tf`

Think of variables like **fill-in-the-blank settings**. Instead of typing
"t3.micro" directly into your main recipe, you make a variable called
`instance_type` and set its default to "t3.micro." This way, if you ever want to
change it, you only change it in ONE place.

```hcl
variable "aws_region" {
  description = "The AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}
```

- `variable "aws_region" { }` — Declares a new fill-in-the-blank setting named
  `aws_region`.
- `description` — Just a note for humans explaining what this setting is for. It
  doesn't affect how the code runs.
- `type = string` — This means the value must be text (letters/words), not a
  number or true/false.
- `default = "us-east-1"` — If you don't provide your own value, Terraform will
  automatically use `"us-east-1"`.

```hcl
variable "instance_type" {
  description = "The EC2 instance type"
  type        = string
  default     = "t3.micro"
}
```

- This sets what **size/power level** of computer you're renting. Think of it like
  choosing between a phone, a laptop, or a gaming PC — they cost different amounts
  and have different power.
- `t3.micro` is one of the smallest and cheapest options AWS offers. It's often
  included for free under AWS's "Free Tier" for new accounts (with some monthly
  limits), which is why it was chosen here.

```hcl
variable "instance_name" {
  description = "Value for the Name tag for the EC2 instance"
  type        = string
  default     = "MyTerraformInstance"
}
```

- This just sets the **nickname/label** that will show up on your AWS dashboard so
  you can recognize this computer among others you might create later.

---

## 5. Line-by-Line: `main.tf`

This is the heart of the project — the actual instructions to build something.

```hcl
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}
```

- A **data block** doesn't create anything new — it just **looks something up**,
  kind of like doing a search.
- An **AMI (Amazon Machine Image)** is like a pre-made "template" or "snapshot" of
  an operating system (like Windows or Linux) that AWS uses to start your
  computer. Instead of installing an operating system yourself, you pick a
  template that already has one ready to go.
- `most_recent = true` — "Find me the newest version of this template" instead of
  an old outdated one.
- `owners = ["amazon"]` — "Only look at templates that were officially made by
  Amazon" (not some random person who uploaded their own).
- `filter { }` — This narrows down the search.
  - `name = "name"` — We're filtering by the template's name.
  - `values = ["al2023-ami-2023.*-x86_64"]` — We only want templates named like
    "Amazon Linux 2023" that work on `x86_64` computer chips (a very common
    computer processor type). The `*` is a wildcard, meaning "anything can go
    here" (like the date the image was built).
- **Why do this instead of typing an exact ID?** AWS releases new updated versions
  of this template all the time, and each one has a different ID. By searching
  instead of hardcoding an ID, your project automatically always uses the latest,
  safest version.

```hcl
resource "aws_instance" "web_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  tags = {
    Name        = var.instance_name
    Environment = "Development"
  }
}
```

- A **resource block** is the real deal — this is the part that tells Terraform
  "actually build/create this thing in AWS."
- `resource "aws_instance" "web_server"` — We're creating a resource of type
  `aws_instance` (a virtual computer), and we're internally nicknaming it
  `web_server` so other files can refer to it.
- `ami = data.aws_ami.amazon_linux.id` — "Use the template we found above" (the ID
  from that search).
- `instance_type = var.instance_type` — "Use the size setting from our variables
  file" (t3.micro by default).
- `tags = { }` — **Tags** are just labels/stickers you put on your AWS resources so
  they're easy to find and organize later, kind of like labeling boxes when you
  move houses.
  - `Name = var.instance_name` — The label shown in the AWS dashboard.
  - `Environment = "Development"` — A label saying this is a test/practice
    computer, not a real important "production" one businesses rely on.

---

## 6. Line-by-Line: `outputs.tf`

After Terraform finishes building things, it doesn't automatically tell you
useful details unless you ask. **Outputs** are like asking Terraform: "hey, print
this specific piece of info on the screen when you're done."

```hcl
output "instance_id" {
  description = "The ID of the EC2 instance"
  value       = aws_instance.web_server.id
}
```

- This prints out the unique ID number AWS assigned to your new computer, like a
  serial number.

```hcl
output "instance_public_ip" {
  description = "The public IP address of the EC2 instance"
  value       = aws_instance.web_server.public_ip
}
```

- This prints out the **public IP address** — think of it like the "phone number"
  or "home address" other computers on the internet would use to find and connect
  to your new server.

---

## 7. How to Run Everything (Step-by-Step)

Before you start, make sure you have:
1. **Terraform installed** on your computer.
2. **AWS credentials configured** (an AWS account with an access key and secret
   key set up, usually through the AWS CLI or environment variables). Terraform
   needs permission to act on your behalf — like giving someone a key to your
   house so they can build furniture inside it.

Open a terminal (command line window) and navigate into the project folder:

```bash
cd terraform-ec2-setup
```

### Step 1 — `terraform init`

```bash
terraform init
```

**What it does:** This is like unpacking your toolbox before starting a project.
Terraform reads your files, sees that you need the AWS plugin, and downloads it.
It also sets up a "state file" — a notebook where Terraform will keep track of
everything it builds, so it remembers what exists later.

You only need to run this once per project (or whenever you add new providers).

### Step 2 — `terraform plan`

```bash
terraform plan
```

**What it does:** This is a **dry run** — like reading a recipe out loud before
actually cooking anything. Terraform will tell you exactly what it *plans* to
create, change, or destroy, but it won't actually touch AWS yet. This is your
chance to double check everything looks right before committing.

### Step 3 — `terraform apply`

```bash
terraform apply
```

**What it does:** This is the real deal — Terraform will show you the plan again
and ask "Do you really want to perform these actions?" Type:

```
yes
```

and press Enter. Terraform will now actually reach out to AWS and build your EC2
instance for real. When it's done, it will print out the outputs we set up
earlier (the instance ID and public IP address).

**Tip:** If you don't want to be asked to confirm every time (careful with this!),
you can run:

```bash
terraform apply -auto-approve
```

This skips the "yes" prompt and applies immediately.

### Step 4 — Check your work

You can log into the AWS Console (the website) and look under **EC2 > Instances**
to see your new computer running, with the name tag you set earlier.

### Step 5 — `terraform destroy` (Clean up!)

```bash
terraform destroy
```

**What it does:** AWS charges you money for computers that are running, even
small ones. When you're done experimenting, this command tells Terraform "undo
everything you built." It will show you what it's about to delete and ask you to
confirm. Type:

```
yes
```

and Terraform will shut down and remove the EC2 instance, so you stop getting
charged for it.

**Important:** Always remember to run `terraform destroy` when you're done
testing — it's very easy to forget a running computer and get a surprise bill
later!

---

## 8. Quick Command Cheat Sheet

| Command | What it means in plain English |
|---|---|
| `terraform init` | "Get your tools ready and download the AWS plugin." |
| `terraform plan` | "Show me what you're about to do, but don't do it yet." |
| `terraform apply` | "Okay, go ahead and actually build it." |
| `terraform destroy` | "Take it all down and clean up." |

---

## 9. Common Questions

**Q: Will this cost me money?**
A: `t3.micro` instances are often free or very cheap under AWS's Free Tier
(usually limited hours per month for new accounts), but you should always check
your AWS billing dashboard to be sure. Running it for a long time or forgetting
to destroy it could cost money.

**Q: What if I want a bigger/more powerful computer?**
A: Just change the `default` value in `variables.tf` for `instance_type` to
something like `t3.small` or `t3.medium` (bigger instance types cost more), then
run `terraform apply` again.

**Q: What if I mess something up?**
A: That's the beauty of Terraform — just run `terraform destroy` to remove
everything, fix your files, and run `terraform apply` again to rebuild from
scratch.
