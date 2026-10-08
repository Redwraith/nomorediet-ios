import Foundation

/// A food from the built-in list or from Open Food Facts. Values are per 100 g.
struct Food: Identifiable, Hashable {
    var id: String { (barcode ?? "") + "|" + name }
    var name: String
    var per100: Nutrients
    /// A typical portion in grams and how it is called ("1 uovo", "1 cucchiaio").
    var portion: Double
    var portionName: String
    var barcode: String? = nil
    var brand: String? = nil
    var source: Source = .builtIn

    enum Source: Hashable { case builtIn, custom, openFoodFacts, database }
}

/// Common Italian foods with approximate values per 100 g (CREA and USDA tables),
/// weighted toward a vegetarian diet. Micronutrients: iron and zinc in mg, calcium in mg, B12 in µg.
enum FoodDatabase {
    private static func f(_ name: String, _ kcal: Double, _ p: Double, _ c: Double, _ fat: Double, fiber: Double = 0,
                          iron: Double = 0, ca: Double = 0, b12: Double = 0, zinc: Double = 0,
                          portion: Double = 100, _ portionName: String = "porzione") -> Food {
        Food(name: name, per100: Nutrients(kcal: kcal, protein: p, carbs: c, fat: fat, fiber: fiber,
                                           iron: iron, calcium: ca, b12: b12, zinc: zinc),
             portion: portion, portionName: portionName)
    }

    static let foods: [Food] = [
        // Cereali, pane, pasta
        f("Pasta di semola (cruda)", 353, 12.5, 72, 1.5, fiber: 3, iron: 1.3, ca: 22, zinc: 1.3, portion: 80, "1 piatto"),
        f("Pasta integrale (cruda)", 340, 13, 64, 2.5, fiber: 8, iron: 3.2, ca: 30, zinc: 2.4, portion: 80, "1 piatto"),
        f("Pasta cotta", 158, 5.8, 31, 0.9, fiber: 1.8, iron: 0.5, ca: 7, zinc: 0.5, portion: 200, "1 piatto"),
        f("Riso bianco (crudo)", 332, 6.7, 80, 0.4, fiber: 1, iron: 0.8, ca: 9, zinc: 1.1, portion: 80, "1 piatto"),
        f("Riso basmati cotto", 130, 2.7, 28, 0.3, fiber: 0.4, iron: 0.2, ca: 10, zinc: 0.5, portion: 180, "1 piatto"),
        f("Riso integrale (crudo)", 362, 7.5, 76, 2.7, fiber: 3.5, iron: 1.5, ca: 23, zinc: 2, portion: 80, "1 piatto"),
        f("Farro (crudo)", 335, 15, 67, 2.5, fiber: 7, iron: 2.5, ca: 27, zinc: 3, portion: 80, "1 piatto"),
        f("Orzo perlato (crudo)", 319, 10, 70, 1.2, fiber: 9, iron: 2.5, ca: 29, zinc: 2.1, portion: 80, "1 piatto"),
        f("Quinoa (cruda)", 368, 14, 64, 6, fiber: 7, iron: 4.6, ca: 47, zinc: 3.1, portion: 70, "1 piatto"),
        f("Couscous (crudo)", 360, 12.8, 72, 0.6, fiber: 5, iron: 1.1, ca: 24, zinc: 0.8, portion: 70, "1 piatto"),
        f("Fiocchi d'avena", 372, 13.5, 59, 7, fiber: 10, iron: 4.2, ca: 54, zinc: 3.6, portion: 40, "1 tazza"),
        f("Muesli", 360, 10, 66, 6, fiber: 7.5, iron: 3.5, ca: 50, zinc: 2.5, portion: 40, "1 tazza"),
        f("Corn flakes", 370, 7, 84, 0.9, fiber: 3, iron: 8, ca: 5, zinc: 0.3, portion: 30, "1 tazza"),
        f("Pane comune", 270, 8.5, 56, 1, fiber: 3, iron: 1.5, ca: 20, zinc: 0.9, portion: 50, "1 fetta"),
        f("Pane integrale", 245, 9, 46, 2.5, fiber: 7, iron: 2.5, ca: 30, zinc: 1.8, portion: 50, "1 fetta"),
        f("Pane di segale", 240, 8, 47, 1.7, fiber: 6, iron: 2.5, ca: 25, zinc: 1.3, portion: 40, "1 fetta"),
        f("Fette biscottate", 410, 11, 75, 6, fiber: 3.5, iron: 2, ca: 30, zinc: 1, portion: 10, "1 fetta"),
        f("Gallette di riso", 380, 8, 80, 3, fiber: 3.5, iron: 1.4, ca: 10, zinc: 1.8, portion: 8, "1 galletta"),
        f("Crackers", 428, 9.5, 74, 10, fiber: 3, iron: 1.6, ca: 20, zinc: 0.8, portion: 25, "1 pacchetto"),
        f("Grissini", 430, 12, 68, 13, fiber: 3.5, iron: 1.5, ca: 20, zinc: 1, portion: 20, "4 grissini"),
        f("Piadina", 330, 8, 52, 10, fiber: 2.5, iron: 1.2, ca: 20, zinc: 0.6, portion: 100, "1 piadina"),
        f("Pizza margherita", 270, 11, 33, 10, fiber: 2, iron: 1, ca: 150, b12: 0.3, zinc: 1.2, portion: 300, "1 pizza"),
        f("Focaccia", 300, 7, 42, 12, fiber: 2, iron: 1.2, ca: 20, zinc: 0.6, portion: 100, "1 trancio"),
        f("Polenta cotta", 70, 1.6, 15, 0.3, fiber: 1, iron: 0.3, ca: 2, zinc: 0.2, portion: 250, "1 piatto"),
        f("Gnocchi di patate", 160, 3.5, 34, 0.5, fiber: 2, iron: 0.6, ca: 15, zinc: 0.4, portion: 200, "1 piatto"),
        f("Patate", 77, 2, 17, 0.1, fiber: 2.2, iron: 0.8, ca: 12, zinc: 0.3, portion: 200, "2 patate medie"),
        f("Patate dolci", 86, 1.6, 20, 0.1, fiber: 3, iron: 0.6, ca: 30, zinc: 0.3, portion: 200, "1 patata"),

        // Legumi e proteine vegetali
        f("Ceci cotti", 164, 8.9, 27, 2.6, fiber: 7.6, iron: 2.9, ca: 49, zinc: 1.5, portion: 150, "1 piatto"),
        f("Lenticchie cotte", 116, 9, 20, 0.4, fiber: 7.9, iron: 3.3, ca: 19, zinc: 1.3, portion: 150, "1 piatto"),
        f("Fagioli borlotti cotti", 132, 9, 24, 0.5, fiber: 8, iron: 2.5, ca: 50, zinc: 1, portion: 150, "1 piatto"),
        f("Fagioli cannellini cotti", 120, 8, 21, 0.4, fiber: 6.5, iron: 2.9, ca: 70, zinc: 1.1, portion: 150, "1 piatto"),
        f("Piselli", 81, 5.4, 14, 0.4, fiber: 5.7, iron: 1.5, ca: 25, zinc: 1.2, portion: 150, "1 porzione"),
        f("Edamame", 121, 12, 9, 5, fiber: 5, iron: 2.3, ca: 63, zinc: 1.4, portion: 100, "1 ciotola"),
        f("Tofu", 144, 15.8, 2.8, 8.7, fiber: 2.3, iron: 2.7, ca: 350, zinc: 1.6, portion: 125, "1 panetto"),
        f("Tempeh", 192, 20, 7.6, 10.8, fiber: 5, iron: 2.7, ca: 111, zinc: 1.1, portion: 100, "1 panetto"),
        f("Seitan", 120, 22, 4, 2, fiber: 0.6, iron: 1.2, ca: 30, zinc: 0.8, portion: 100, "1 porzione"),
        f("Bevanda di soia", 40, 3.3, 1.5, 1.8, fiber: 0.5, iron: 0.4, ca: 120, b12: 0.38, zinc: 0.3, portion: 250, "1 tazza"),
        f("Yogurt di soia", 55, 4, 3, 2.5, fiber: 1, iron: 0.6, ca: 120, b12: 0.38, zinc: 0.3, portion: 125, "1 vasetto"),
        f("Hummus", 177, 7.9, 14, 9.6, fiber: 6, iron: 2.4, ca: 38, zinc: 1.8, portion: 50, "2 cucchiai"),
        f("Burger vegetale", 200, 17, 8, 11, fiber: 4, iron: 2.5, ca: 40, b12: 0.5, zinc: 1.2, portion: 100, "1 burger"),
        f("Proteine whey in polvere", 380, 78, 8, 5, iron: 1, ca: 450, b12: 1, zinc: 2.5, portion: 30, "1 misurino"),
        f("Proteine vegetali in polvere", 370, 75, 6, 6, fiber: 3, iron: 15, ca: 100, zinc: 4, portion: 30, "1 misurino"),

        // Uova e latticini
        f("Uovo intero", 143, 12.6, 0.7, 9.5, iron: 1.8, ca: 56, b12: 0.9, zinc: 1.3, portion: 60, "1 uovo"),
        f("Albume", 52, 10.9, 0.7, 0.2, iron: 0.1, ca: 7, b12: 0.1, portion: 33, "1 albume"),
        f("Latte parzialmente scremato", 46, 3.4, 5, 1.6, ca: 120, b12: 0.4, zinc: 0.4, portion: 200, "1 bicchiere"),
        f("Latte intero", 64, 3.3, 4.8, 3.6, ca: 119, b12: 0.4, zinc: 0.4, portion: 200, "1 bicchiere"),
        f("Yogurt greco 0%", 57, 10, 3.6, 0.4, ca: 110, b12: 0.7, zinc: 0.5, portion: 170, "1 vasetto"),
        f("Yogurt greco intero", 97, 9, 4, 5, ca: 100, b12: 0.7, zinc: 0.5, portion: 150, "1 vasetto"),
        f("Yogurt bianco", 61, 3.5, 4.7, 3.3, ca: 121, b12: 0.4, zinc: 0.6, portion: 125, "1 vasetto"),
        f("Skyr", 63, 11, 4, 0.2, ca: 150, b12: 0.5, zinc: 0.5, portion: 150, "1 vasetto"),
        f("Fiocchi di latte", 98, 11.1, 3.4, 4.3, ca: 83, b12: 0.4, zinc: 0.4, portion: 150, "1 vasetto"),
        f("Ricotta vaccina", 146, 8.8, 3.5, 10.9, ca: 295, b12: 0.3, zinc: 1.2, portion: 100, "1 porzione"),
        f("Mozzarella", 253, 18.7, 0.7, 19.5, ca: 350, b12: 1.1, zinc: 2.5, portion: 125, "1 mozzarella"),
        f("Mozzarella light", 163, 19, 1, 9, ca: 400, b12: 1.1, zinc: 2.5, portion: 125, "1 mozzarella"),
        f("Parmigiano Reggiano", 392, 33, 0, 28, ca: 1160, b12: 1.2, zinc: 4, portion: 10, "1 cucchiaio"),
        f("Grana Padano", 384, 33, 0, 28, ca: 1165, b12: 1.2, zinc: 4, portion: 10, "1 cucchiaio"),
        f("Feta", 264, 14, 4, 21, iron: 0.6, ca: 490, b12: 1.7, zinc: 2.9, portion: 50, "1 porzione"),
        f("Stracchino", 300, 18.5, 0, 25, ca: 570, b12: 1, zinc: 2.5, portion: 100, "1 porzione"),
        f("Scamorza", 334, 25, 1, 25.6, ca: 700, b12: 1.2, zinc: 3, portion: 80, "1 porzione"),
        f("Burro", 717, 0.9, 0.1, 81, ca: 24, b12: 0.2, portion: 10, "1 noce"),
        f("Panna da cucina", 205, 2.5, 3.5, 20, ca: 80, b12: 0.2, portion: 50, "1/4 di confezione"),

        // Carne e pesce (per chi li mangia)
        f("Petto di pollo", 110, 23, 0, 1.5, iron: 0.4, ca: 5, b12: 0.3, zinc: 0.8, portion: 150, "1 petto"),
        f("Tacchino a fette", 107, 24, 0, 1, iron: 0.6, ca: 10, b12: 0.4, zinc: 1.3, portion: 150, "1 porzione"),
        f("Manzo magro", 130, 21, 0, 5, iron: 2.2, ca: 10, b12: 2, zinc: 4.5, portion: 150, "1 porzione"),
        f("Prosciutto crudo", 268, 25, 0, 18, iron: 1.2, ca: 10, b12: 0.7, zinc: 2.5, portion: 50, "4 fette"),
        f("Prosciutto cotto", 215, 20, 1, 14, iron: 0.8, ca: 8, b12: 0.5, zinc: 2, portion: 50, "3 fette"),
        f("Bresaola", 151, 32, 0, 2.6, iron: 2.8, ca: 15, b12: 1.5, zinc: 5, portion: 50, "6 fette"),
        f("Salmone", 185, 20, 0, 12, iron: 0.5, ca: 12, b12: 3.2, zinc: 0.5, portion: 150, "1 trancio"),
        f("Tonno al naturale", 103, 25, 0, 0.3, iron: 1, ca: 15, b12: 2.5, zinc: 0.7, portion: 80, "1 scatoletta"),
        f("Merluzzo", 82, 17, 0, 0.7, iron: 0.4, ca: 16, b12: 0.9, zinc: 0.4, portion: 150, "1 filetto"),
        f("Gamberi", 85, 20, 0, 0.5, iron: 0.5, ca: 70, b12: 1.1, zinc: 1.3, portion: 150, "1 porzione"),

        // Verdure
        f("Spinaci", 23, 2.9, 3.6, 0.4, fiber: 2.2, iron: 2.7, ca: 99, zinc: 0.5, portion: 200, "1 porzione"),
        f("Bietole", 19, 1.8, 3.7, 0.2, fiber: 1.6, iron: 1.8, ca: 51, zinc: 0.4, portion: 200, "1 porzione"),
        f("Broccoli", 34, 2.8, 7, 0.4, fiber: 2.6, iron: 0.7, ca: 47, zinc: 0.4, portion: 200, "1 porzione"),
        f("Cavolfiore", 25, 1.9, 5, 0.3, fiber: 2, iron: 0.4, ca: 22, zinc: 0.3, portion: 200, "1 porzione"),
        f("Cavolo nero", 49, 4.3, 9, 0.9, fiber: 3.6, iron: 1.5, ca: 150, zinc: 0.6, portion: 150, "1 porzione"),
        f("Zucchine", 17, 1.2, 3.1, 0.3, fiber: 1, iron: 0.4, ca: 16, zinc: 0.3, portion: 200, "1 porzione"),
        f("Melanzane", 25, 1, 6, 0.2, fiber: 3, iron: 0.2, ca: 9, zinc: 0.2, portion: 200, "1 porzione"),
        f("Peperoni", 31, 1, 6, 0.3, fiber: 2.1, iron: 0.4, ca: 7, zinc: 0.3, portion: 150, "1 peperone"),
        f("Pomodori", 18, 0.9, 3.9, 0.2, fiber: 1.2, iron: 0.3, ca: 10, zinc: 0.2, portion: 150, "1 pomodoro grande"),
        f("Passata di pomodoro", 30, 1.5, 5.5, 0.2, fiber: 1.5, iron: 1, ca: 15, zinc: 0.3, portion: 100, "per 1 piatto"),
        f("Carote", 41, 0.9, 10, 0.2, fiber: 2.8, iron: 0.3, ca: 33, zinc: 0.2, portion: 100, "1 carota"),
        f("Insalata verde", 15, 1.4, 2.9, 0.2, fiber: 1.3, iron: 0.9, ca: 36, zinc: 0.2, portion: 80, "1 ciotola"),
        f("Rucola", 25, 2.6, 3.7, 0.7, fiber: 1.6, iron: 1.5, ca: 160, zinc: 0.5, portion: 50, "1 manciata"),
        f("Finocchi", 31, 1.2, 7, 0.2, fiber: 3.1, iron: 0.7, ca: 49, zinc: 0.2, portion: 200, "1 finocchio"),
        f("Funghi champignon", 22, 3.1, 3.3, 0.3, fiber: 1, iron: 0.5, ca: 3, zinc: 0.5, portion: 150, "1 porzione"),
        f("Cipolla", 40, 1.1, 9, 0.1, fiber: 1.7, iron: 0.2, ca: 23, zinc: 0.2, portion: 50, "mezza cipolla"),
        f("Asparagi", 20, 2.2, 3.9, 0.1, fiber: 2.1, iron: 2.1, ca: 24, zinc: 0.5, portion: 150, "1 porzione"),
        f("Fagiolini", 31, 1.8, 7, 0.2, fiber: 2.7, iron: 1, ca: 37, zinc: 0.2, portion: 150, "1 porzione"),
        f("Zucca", 26, 1, 6.5, 0.1, fiber: 0.5, iron: 0.8, ca: 21, zinc: 0.3, portion: 200, "1 porzione"),
        f("Carciofi", 47, 3.3, 10.5, 0.2, fiber: 5.4, iron: 1.3, ca: 44, zinc: 0.5, portion: 150, "2 carciofi"),
        f("Minestrone di verdure", 40, 1.8, 6.5, 0.8, fiber: 2, iron: 0.6, ca: 25, zinc: 0.3, portion: 300, "1 piatto"),

        // Frutta
        f("Mela", 52, 0.3, 14, 0.2, fiber: 2.4, iron: 0.1, ca: 6, portion: 180, "1 mela"),
        f("Banana", 89, 1.1, 23, 0.3, fiber: 2.6, iron: 0.3, ca: 5, zinc: 0.2, portion: 120, "1 banana"),
        f("Arancia", 47, 0.9, 12, 0.1, fiber: 2.4, iron: 0.1, ca: 40, portion: 200, "1 arancia"),
        f("Pera", 57, 0.4, 15, 0.1, fiber: 3.1, iron: 0.2, ca: 9, portion: 180, "1 pera"),
        f("Kiwi", 61, 1.1, 15, 0.5, fiber: 3, iron: 0.3, ca: 34, zinc: 0.1, portion: 75, "1 kiwi"),
        f("Fragole", 32, 0.7, 7.7, 0.3, fiber: 2, iron: 0.4, ca: 16, zinc: 0.1, portion: 150, "1 ciotola"),
        f("Frutti di bosco", 50, 0.9, 11, 0.4, fiber: 4, iron: 0.6, ca: 20, zinc: 0.2, portion: 125, "1 vaschetta"),
        f("Uva", 69, 0.7, 18, 0.2, fiber: 0.9, iron: 0.4, ca: 10, portion: 150, "1 grappolo piccolo"),
        f("Mandarini", 53, 0.8, 13, 0.3, fiber: 1.8, iron: 0.2, ca: 37, portion: 80, "1 mandarino"),
        f("Pesca", 39, 0.9, 10, 0.3, fiber: 1.5, iron: 0.3, ca: 6, portion: 150, "1 pesca"),
        f("Ananas", 50, 0.5, 13, 0.1, fiber: 1.4, iron: 0.3, ca: 13, portion: 150, "2 fette"),
        f("Mango", 60, 0.8, 15, 0.4, fiber: 1.6, iron: 0.2, ca: 11, portion: 150, "mezzo mango"),
        f("Avocado", 160, 2, 8.5, 14.7, fiber: 6.7, iron: 0.6, ca: 12, zinc: 0.6, portion: 100, "mezzo avocado"),
        f("Datteri secchi", 282, 2.5, 75, 0.4, fiber: 8, iron: 1, ca: 39, zinc: 0.3, portion: 25, "3 datteri"),
        f("Albicocche secche", 241, 3.4, 63, 0.5, fiber: 7.3, iron: 2.7, ca: 55, zinc: 0.4, portion: 30, "5 albicocche"),

        // Frutta secca, semi, condimenti
        f("Mandorle", 579, 21, 22, 50, fiber: 12.5, iron: 3.7, ca: 269, zinc: 3.1, portion: 30, "1 manciata"),
        f("Noci", 654, 15, 14, 65, fiber: 6.7, iron: 2.9, ca: 98, zinc: 3.1, portion: 30, "1 manciata"),
        f("Anacardi", 553, 18, 30, 44, fiber: 3.3, iron: 6.7, ca: 37, zinc: 5.8, portion: 30, "1 manciata"),
        f("Nocciole", 628, 15, 17, 61, fiber: 9.7, iron: 4.7, ca: 114, zinc: 2.5, portion: 30, "1 manciata"),
        f("Pistacchi", 560, 20, 28, 45, fiber: 10.6, iron: 3.9, ca: 105, zinc: 2.2, portion: 30, "1 manciata"),
        f("Arachidi", 567, 26, 16, 49, fiber: 8.5, iron: 4.6, ca: 92, zinc: 3.3, portion: 30, "1 manciata"),
        f("Burro di arachidi", 588, 25, 20, 50, fiber: 6, iron: 1.9, ca: 43, zinc: 2.5, portion: 15, "1 cucchiaio"),
        f("Semi di zucca", 559, 30, 11, 49, fiber: 6, iron: 8.8, ca: 46, zinc: 7.8, portion: 15, "1 cucchiaio"),
        f("Semi di chia", 486, 17, 42, 31, fiber: 34, iron: 7.7, ca: 631, zinc: 4.6, portion: 15, "1 cucchiaio"),
        f("Semi di lino", 534, 18, 29, 42, fiber: 27, iron: 5.7, ca: 255, zinc: 4.3, portion: 10, "1 cucchiaio"),
        f("Semi di sesamo / tahina", 595, 17, 21, 54, fiber: 9, iron: 9, ca: 420, zinc: 4.6, portion: 15, "1 cucchiaio"),
        f("Olio extravergine d'oliva", 899, 0, 0, 99.9, iron: 0.6, ca: 1, portion: 10, "1 cucchiaio"),
        f("Pesto alla genovese", 450, 5, 6, 45, fiber: 2, iron: 1, ca: 150, zinc: 0.6, portion: 30, "per 1 piatto"),
        f("Maionese", 680, 1, 1, 75, ca: 8, b12: 0.2, portion: 15, "1 cucchiaio"),

        // Dolci, snack, bevande
        f("Cioccolato fondente 70%", 580, 7.8, 46, 41, fiber: 11, iron: 11.9, ca: 73, zinc: 3.3, portion: 20, "2 quadretti"),
        f("Cioccolato al latte", 545, 7.6, 59, 30, fiber: 3.4, iron: 2.4, ca: 190, b12: 0.7, zinc: 2.3, portion: 20, "2 quadretti"),
        f("Biscotti secchi", 430, 7, 76, 10, fiber: 2.5, iron: 1.5, ca: 30, zinc: 0.6, portion: 30, "4 biscotti"),
        f("Cornetto", 410, 7, 45, 22, fiber: 2, iron: 1, ca: 30, b12: 0.2, zinc: 0.6, portion: 60, "1 cornetto"),
        f("Crema spalmabile alla nocciola", 539, 6.3, 57, 31, fiber: 3.4, iron: 2.4, ca: 108, zinc: 1, portion: 15, "1 cucchiaio"),
        f("Marmellata", 250, 0.5, 60, 0.1, fiber: 1, iron: 0.4, ca: 15, portion: 20, "1 cucchiaio"),
        f("Miele", 304, 0.3, 82, 0, iron: 0.4, ca: 6, portion: 10, "1 cucchiaino"),
        f("Zucchero", 400, 0, 100, 0, portion: 5, "1 cucchiaino"),
        f("Gelato alla crema", 207, 3.5, 24, 11, ca: 130, b12: 0.4, zinc: 0.5, portion: 100, "1 coppetta"),
        f("Barretta proteica", 360, 33, 33, 12, fiber: 6, iron: 2, ca: 150, b12: 0.5, zinc: 2, portion: 55, "1 barretta"),
        f("Patatine", 536, 7, 53, 34, fiber: 4.4, iron: 1.6, ca: 24, zinc: 0.7, portion: 25, "1 pacchetto"),
        f("Caffè espresso", 2, 0.1, 0, 0, portion: 30, "1 tazzina"),
        f("Cappuccino", 45, 2.5, 4, 2, ca: 85, b12: 0.3, zinc: 0.3, portion: 150, "1 tazza"),
        f("Succo d'arancia", 45, 0.7, 10, 0.2, fiber: 0.2, iron: 0.2, ca: 11, portion: 200, "1 bicchiere"),
        f("Birra", 43, 0.5, 3.6, 0, ca: 4, portion: 330, "1 lattina"),
        f("Vino rosso", 85, 0.1, 2.6, 0, iron: 0.5, ca: 8, portion: 125, "1 bicchiere"),
        f("Bibita zuccherata", 42, 0, 10.6, 0, portion: 330, "1 lattina"),
    ]

    /// Search that ignores accents and case, matching every word typed.
    static func search(_ text: String, extra: [Food] = []) -> [Food] {
        let words = normalize(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let all = extra + foods
        return all.filter { food in
            let name = normalize(food.name + " " + (food.brand ?? ""))
            return words.allSatisfy { name.contains($0) }
        }
        .sorted { a, b in
            let an = normalize(a.name), bn = normalize(b.name)
            let ap = an.hasPrefix(words[0]), bp = bn.hasPrefix(words[0])
            return ap != bp ? ap : an.count < bn.count
        }
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .replacingOccurrences(of: "'", with: " ")
    }
}
